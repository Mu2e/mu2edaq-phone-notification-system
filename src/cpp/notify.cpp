// Implementation of the mu2edaq_notify C++ publisher.

#include "mu2edaq_notify/notify.hpp"

#include <curl/curl.h>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <random>
#include <sstream>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socket_t = SOCKET;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_t = int;
static const socket_t INVALID_SOCKET = -1;
#endif

namespace mu2edaq {
namespace notify {

namespace {

const char* kDiscoveryGroup = "239.255.42.99";
const int kDiscoveryPort = 28999;

std::string getenv_str(const char* name) {
    const char* v = std::getenv(name);
    return v ? std::string(v) : std::string();
}

std::string local_hostname() {
    char buf[256] = {0};
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    if (gethostname(buf, sizeof(buf) - 1) != 0) return "unknown";
    return buf;
}

size_t discard_body(char*, size_t size, size_t nmemb, void*) {
    return size * nmemb;
}

// Pull a JSON string or number value out of a flat JSON object without
// a JSON library. Good enough for the small, known ANNOUNCE messages.
std::string json_field(const std::string& doc, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    auto pos = doc.find(needle);
    if (pos == std::string::npos) return "";
    pos = doc.find(':', pos + needle.size());
    if (pos == std::string::npos) return "";
    ++pos;
    while (pos < doc.size() && (doc[pos] == ' ' || doc[pos] == '\t')) ++pos;
    if (pos >= doc.size()) return "";
    if (doc[pos] == '"') {
        std::string out;
        for (++pos; pos < doc.size() && doc[pos] != '"'; ++pos) {
            if (doc[pos] == '\\' && pos + 1 < doc.size()) ++pos;
            out += doc[pos];
        }
        return out;
    }
    std::string out;
    while (pos < doc.size() &&
           (std::isdigit(static_cast<unsigned char>(doc[pos])) ||
            doc[pos] == '.' || doc[pos] == '-')) {
        out += doc[pos++];
    }
    return out;
}

std::string random_qid() {
    static const char* hex = "0123456789abcdef";
    std::mt19937 gen(std::random_device{}());
    std::uniform_int_distribution<int> d(0, 15);
    std::string out;
    for (int i = 0; i < 32; ++i) {
        out += hex[d(gen)];
        if (i == 7 || i == 11 || i == 15 || i == 19) out += '-';
    }
    return out;
}

}  // namespace

std::string Publisher::json_escape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (unsigned char c : in) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

std::string Publisher::build_payload(const std::string& severity,
                                     const std::string& title,
                                     const std::string& message,
                                     const std::string& source,
                                     const std::string& host,
                                     const Meta& meta) {
    std::ostringstream os;
    os << "{\"severity\":\"" << json_escape(severity) << "\","
       << "\"title\":\"" << json_escape(title) << "\","
       << "\"message\":\"" << json_escape(message) << "\","
       << "\"source\":\"" << json_escape(source) << "\","
       << "\"host\":\"" << json_escape(host) << "\","
       << "\"meta\":{";
    bool first = true;
    for (const auto& kv : meta) {
        if (!first) os << ",";
        first = false;
        os << "\"" << json_escape(kv.first) << "\":\""
           << json_escape(kv.second) << "\"";
    }
    os << "}}";
    return os.str();
}

DiscoveredServer discover_server_pair(double timeout_s) {
    DiscoveredServer result;
#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return result;
#endif
    socket_t sock = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) return result;

    const std::string qid = random_qid();
    const std::string query =
        "{\"proto\":\"mu2edaq-discovery/1\",\"type\":\"DISCOVER\","
        "\"qid\":\"" + qid + "\",\"filter\":{\"app\":\"notify\"}}";

    sockaddr_in group{};
    group.sin_family = AF_INET;
    group.sin_port = htons(kDiscoveryPort);
    inet_pton(AF_INET, kDiscoveryGroup, &group.sin_addr);

#ifdef _WIN32
    DWORD tv = static_cast<DWORD>(timeout_s * 1000);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char*>(&tv), sizeof(tv));
#else
    timeval tv{};
    tv.tv_sec = static_cast<long>(timeout_s);
    tv.tv_usec = static_cast<long>((timeout_s - tv.tv_sec) * 1e6);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
    unsigned char ttl = 4;
    setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL,
               reinterpret_cast<const char*>(&ttl), sizeof(ttl));

    if (::sendto(sock, query.data(), static_cast<int>(query.size()), 0,
                 reinterpret_cast<sockaddr*>(&group), sizeof(group)) >= 0) {
        char buf[1500];
        auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::duration<double>(timeout_s);
        while (std::chrono::steady_clock::now() < deadline) {
            auto n = ::recv(sock, buf, sizeof(buf) - 1, 0);
            if (n <= 0) break;
            buf[n] = '\0';
            std::string doc(buf);
            if (json_field(doc, "type") != "ANNOUNCE") continue;
            if (json_field(doc, "qid") != qid) continue;
            std::string host = json_field(doc, "host");
            std::string port = json_field(doc, "port");
            std::string scheme = json_field(doc, "scheme");
            if (!host.empty() && !port.empty()) {
                result.primary = (scheme.empty() ? "http" : scheme) +
                                 "://" + host + ":" + port;
                result.fallback = json_field(doc, "fallback_url");
                break;
            }
        }
    }
#ifdef _WIN32
    closesocket(sock);
#else
    ::close(sock);
#endif
    return result;
}

std::string discover_server(double timeout_s) {
    return discover_server_pair(timeout_s).primary;
}

Publisher::Publisher(Options opts) : opts_(std::move(opts)) {
    if (opts_.token.empty()) opts_.token = getenv_str("MU2EDAQ_NOTIFY_TOKEN");
    if (opts_.host.empty()) opts_.host = local_hostname();
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

void Publisher::resolve_server() {
    if (resolved_) return;
    if (opts_.server_url.empty())
        opts_.server_url = getenv_str("MU2EDAQ_NOTIFY_URL");
    if (opts_.fallback_url.empty())
        opts_.fallback_url = getenv_str("MU2EDAQ_NOTIFY_FALLBACK_URL");
    if (opts_.discover &&
        (opts_.server_url.empty() || opts_.fallback_url.empty())) {
        DiscoveredServer d = discover_server_pair();
        if (opts_.server_url.empty()) opts_.server_url = d.primary;
        if (opts_.fallback_url.empty()) opts_.fallback_url = d.fallback;
    }
    resolved_ = true;
}

bool Publisher::post_once(const std::string& base_url,
                          const std::string& payload, bool* unreachable) {
    *unreachable = false;
    std::string url = base_url;
    while (!url.empty() && url.back() == '/') url.pop_back();
    url += "/api/events";

    CURL* curl = curl_easy_init();
    if (!curl) {
        *unreachable = true;
        return false;
    }

    curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    if (!opts_.token.empty()) {
        headers = curl_slist_append(
            headers, ("Authorization: Bearer " + opts_.token).c_str());
    }
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE,
                     static_cast<long>(payload.size()));
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, opts_.timeout_ms);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, discard_body);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

    const CURLcode rc = curl_easy_perform(curl);
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (rc != CURLE_OK) {
        // Transport-level failure (DNS, connection refused, timeout): the
        // server was never reached, so a fallback address is worth trying.
        *unreachable = true;
        return false;
    }
    return status >= 200 && status < 300;
}

bool Publisher::publish(const std::string& severity, const std::string& title,
                        const std::string& message, const Meta& meta) {
    resolve_server();

    std::vector<std::string> urls;
    if (!opts_.server_url.empty()) urls.push_back(opts_.server_url);
    if (!opts_.fallback_url.empty() &&
        opts_.fallback_url != opts_.server_url) {
        urls.push_back(opts_.fallback_url);
    }
    if (urls.empty()) return false;

    const std::string payload = build_payload(severity, title, message,
                                              opts_.source, opts_.host, meta);
    for (const auto& url : urls) {
        bool unreachable = false;
        const bool ok = post_once(url, payload, &unreachable);
        if (!unreachable) return ok;  // reached the server: done either way
    }
    return false;  // every address was unreachable
}

}  // namespace notify
}  // namespace mu2edaq
