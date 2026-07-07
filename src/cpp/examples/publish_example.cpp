// Minimal example: publish one event from C++.
//
//   ./publish_example http://mu2edaq01:8095 my-api-token
//
// With no arguments the server is taken from MU2EDAQ_NOTIFY_URL or
// found via mu2edaq-discovery.

#include <mu2edaq_notify/notify.hpp>

#include <iostream>

int main(int argc, char** argv) {
    mu2edaq::notify::Options opts;
    if (argc > 1) opts.server_url = argv[1];
    if (argc > 2) opts.token = argv[2];
    opts.source = "publish-example";

    mu2edaq::notify::Publisher pub(opts);
    const bool ok = pub.warning("C++ example event",
                                "Hello from the mu2edaq_notify C++ library",
                                {{"example", "true"}});
    std::cout << (ok ? "event accepted" : "event NOT delivered")
              << " (server: "
              << (pub.server_url().empty() ? "<none>" : pub.server_url())
              << ")\n";
    return ok ? 0 : 1;
}
