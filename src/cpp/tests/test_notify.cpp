// CppUnit tests for the mu2edaq_notify C++ publisher (offline parts).

#include <cppunit/TestFixture.h>
#include <cppunit/extensions/HelperMacros.h>
#include <cppunit/ui/text/TestRunner.h>

#include <mu2edaq_notify/notify.hpp>

using mu2edaq::notify::Publisher;

class NotifyTest : public CppUnit::TestFixture {
    CPPUNIT_TEST_SUITE(NotifyTest);
    CPPUNIT_TEST(testJsonEscape);
    CPPUNIT_TEST(testBuildPayload);
    CPPUNIT_TEST(testBuildPayloadCategoryDefaultsToEmpty);
    CPPUNIT_TEST(testPublishWithoutServerFails);
    CPPUNIT_TEST(testPublishReturnsFalseWhenPrimaryAndFallbackUnreachable);
    CPPUNIT_TEST_SUITE_END();

public:
    void testJsonEscape() {
        CPPUNIT_ASSERT_EQUAL(std::string("plain"),
                             Publisher::json_escape("plain"));
        CPPUNIT_ASSERT_EQUAL(std::string("a\\\"b"),
                             Publisher::json_escape("a\"b"));
        CPPUNIT_ASSERT_EQUAL(std::string("line\\nbreak"),
                             Publisher::json_escape("line\nbreak"));
        CPPUNIT_ASSERT_EQUAL(std::string("back\\\\slash"),
                             Publisher::json_escape("back\\slash"));
        CPPUNIT_ASSERT_EQUAL(std::string("\\u0001"),
                             Publisher::json_escape("\x01"));
    }

    void testBuildPayload() {
        const std::string payload = Publisher::build_payload(
            "error", "DTC link down", "ROC link 3 \"lost\" lock",
            "dtc-monitor", "mu2edaq09", {{"run", "107001"}}, "Trigger");
        CPPUNIT_ASSERT(payload.find("\"severity\":\"error\"")
                       != std::string::npos);
        CPPUNIT_ASSERT(payload.find("\"title\":\"DTC link down\"")
                       != std::string::npos);
        CPPUNIT_ASSERT(payload.find("\\\"lost\\\"") != std::string::npos);
        CPPUNIT_ASSERT(payload.find("\"category\":\"Trigger\"")
                       != std::string::npos);
        CPPUNIT_ASSERT(payload.find("\"run\":\"107001\"")
                       != std::string::npos);
        CPPUNIT_ASSERT_EQUAL('{', payload.front());
        CPPUNIT_ASSERT_EQUAL('}', payload.back());
    }

    void testBuildPayloadCategoryDefaultsToEmpty() {
        const std::string payload = Publisher::build_payload(
            "info", "t", "m", "src", "host", {});
        CPPUNIT_ASSERT(payload.find("\"category\":\"\"") != std::string::npos);
    }

    void testPublishWithoutServerFails() {
        mu2edaq::notify::Options opts;
        opts.discover = false;      // no network lookups in unit tests
        opts.server_url = "";
        opts.fallback_url = "";
#ifdef _WIN32
        _putenv("MU2EDAQ_NOTIFY_URL=");
        _putenv("MU2EDAQ_NOTIFY_FALLBACK_URL=");
#else
        unsetenv("MU2EDAQ_NOTIFY_URL");
        unsetenv("MU2EDAQ_NOTIFY_FALLBACK_URL");
#endif
        mu2edaq::notify::Publisher pub(opts);
        CPPUNIT_ASSERT_EQUAL(false, pub.info("should not send"));
    }

    void testPublishReturnsFalseWhenPrimaryAndFallbackUnreachable() {
        mu2edaq::notify::Options opts;
        opts.discover = false;
        opts.server_url = "http://127.0.0.1:1";     // connection refused
        opts.fallback_url = "http://127.0.0.1:2";   // also refused
        opts.timeout_ms = 2000;
        mu2edaq::notify::Publisher pub(opts);
        CPPUNIT_ASSERT_EQUAL(false, pub.warning("both unreachable"));
        CPPUNIT_ASSERT_EQUAL(std::string("http://127.0.0.1:1"),
                             pub.server_url());
        CPPUNIT_ASSERT_EQUAL(std::string("http://127.0.0.1:2"),
                             pub.fallback_url());
    }
};

CPPUNIT_TEST_SUITE_REGISTRATION(NotifyTest);

int main() {
    CppUnit::TextUi::TestRunner runner;
    runner.addTest(CppUnit::TestFactoryRegistry::getRegistry().makeTest());
    return runner.run() ? 0 : 1;
}
