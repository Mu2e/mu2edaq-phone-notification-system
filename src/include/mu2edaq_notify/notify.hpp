// mu2edaq_notify -- C++17 publisher library for the Mu2e DAQ
// notification server.
//
// Publishes events over HTTP (libcurl). The server address can be given
// explicitly, taken from the MU2EDAQ_NOTIFY_URL environment variable, or
// found via the mu2edaq-discovery multicast protocol.
//
//   #include <mu2edaq_notify/notify.hpp>
//
//   mu2edaq::notify::Publisher pub({/*server_url=*/"", /*token=*/"tok"});
//   pub.error("DTC link down", "ROC link 3 lost lock");
//
// Discovery resolves two addresses: a primary (the server's own local
// address) and a fallback (carried in the ANNOUNCE metadata, typically
// the public reverse-proxy URL). publish() tries the primary first and
// only tries the fallback when the primary is unreachable at the
// transport level -- an explicit rejection from the server (bad token,
// bad payload) is not retried against the fallback.
//
// Publishing never throws on delivery failure: a notification must not
// be able to take down a DAQ application.

#ifndef MU2EDAQ_NOTIFY_NOTIFY_HPP
#define MU2EDAQ_NOTIFY_NOTIFY_HPP

#include <map>
#include <string>

namespace mu2edaq {
namespace notify {

struct Options {
    std::string server_url;    // empty: $MU2EDAQ_NOTIFY_URL, then discovery
    std::string fallback_url;  // empty: $MU2EDAQ_NOTIFY_FALLBACK_URL, then
                               // discovery ANNOUNCE meta.fallback_url
    std::string token;         // empty: $MU2EDAQ_NOTIFY_TOKEN
    std::string source = "cpp";
    std::string host;          // empty: gethostname()
    long timeout_ms = 5000;
    bool discover = true;      // use mu2edaq-discovery when no URL is known
};

using Meta = std::map<std::string, std::string>;

class Publisher {
public:
    explicit Publisher(Options opts = {});

    // Send one event. Returns true when the server accepted it.
    bool publish(const std::string& severity, const std::string& title,
                 const std::string& message = "", const Meta& meta = {});

    bool debug(const std::string& t, const std::string& m = "",
               const Meta& x = {}) { return publish("debug", t, m, x); }
    bool info(const std::string& t, const std::string& m = "",
              const Meta& x = {}) { return publish("info", t, m, x); }
    bool warning(const std::string& t, const std::string& m = "",
                 const Meta& x = {}) { return publish("warning", t, m, x); }
    bool error(const std::string& t, const std::string& m = "",
               const Meta& x = {}) { return publish("error", t, m, x); }
    bool critical(const std::string& t, const std::string& m = "",
                  const Meta& x = {}) { return publish("critical", t, m, x); }

    const std::string& server_url() const { return opts_.server_url; }
    const std::string& fallback_url() const { return opts_.fallback_url; }

private:
    Options opts_;
    bool resolved_ = false;
    void resolve_server();
    bool post_once(const std::string& url, const std::string& payload,
                   bool* unreachable);

public:
    // Exposed for unit tests.
    static std::string json_escape(const std::string& in);
    static std::string build_payload(const std::string& severity,
                                     const std::string& title,
                                     const std::string& message,
                                     const std::string& source,
                                     const std::string& host,
                                     const Meta& meta);
};

// Result of a discovery query: the responder's own advertised address
// (primary) plus its meta.fallback_url, if any (fallback).
struct DiscoveredServer {
    std::string primary;
    std::string fallback;
};

// Locate the notification server with a mu2edaq-discovery DISCOVER
// query (multicast 239.255.42.99:28999, filter app=notify).
DiscoveredServer discover_server_pair(double timeout_s = 2.0);

// Convenience wrapper: primary URL only, e.g.
// "http://mu2edaq01.fnal.gov:8095", or "" when nothing answered.
std::string discover_server(double timeout_s = 2.0);

}  // namespace notify
}  // namespace mu2edaq

#endif  // MU2EDAQ_NOTIFY_NOTIFY_HPP
