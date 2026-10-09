#include "../Telemetry.h"

#include <cassert>
#include <map>
#include <set>
#include <string>

class FakeTimestampBackend final : public vrtelemetry::TimestampBackend {
public:
    bool supported() override { return support; }
    uint32_t create() override {
        const uint32_t id = next++;
        values[id] = 0;
        return id;
    }
    void timestamp(uint32_t query) override { values[query] = tick++; }
    bool available(uint32_t query) override {
        ++availabilityChecks;
        return ready.count(query) != 0;
    }
    bool result(uint32_t query, uint64_t* value) override {
        assert(ready.count(query));
        ++resultReads;
        if (!resultSucceeds) return false;
        *value = values[query];
        return true;
    }
    void destroy(uint32_t query) override { destroyed.insert(query); }

    bool support = true;
    bool resultSucceeds = true;
    uint32_t next = 1;
    uint64_t tick = 100;
    int availabilityChecks = 0;
    int resultReads = 0;
    std::map<uint32_t, uint64_t> values;
    std::set<uint32_t> ready;
    std::set<uint32_t> destroyed;
};

static vrtelemetry::DrmClientCounters client(const char* text) {
    vrtelemetry::DrmClientCounters value;
    assert(vrtelemetry::parseDrmFdInfo(text, &value));
    return value;
}

int main() {
    using Ring = vrtelemetry::TimestampRing<1>;
    FakeTimestampBackend unsupportedBackend;
    unsupportedBackend.support = false;
    Ring unsupported;
    assert(!unsupported.probe(unsupportedBackend));
    assert(unsupported.status() == Ring::QueryStatus::Unsupported);
    assert(!unsupported.begin(unsupportedBackend, "scene", 1, "A/above"));
    assert(unsupported.pending() == 0 && unsupported.dropped() == 0);

    FakeTimestampBackend backend;
    Ring ring;
    assert(ring.begin(backend, "source_scene_eye1", 42, "PEWTER_CITY/above"));
    ring.end(backend);
    assert(ring.pending() == 1);
    assert(!ring.begin(backend, "overflow", 43, "PEWTER_GYM/above"));
    assert(ring.dropped() == 1);
    ring.resetCounters();
    assert(ring.dropped() == 0 && ring.pending() == 1
        && ring.status() == Ring::QueryStatus::Available);
    const auto waiting = ring.poll(backend);
    assert(waiting.empty());
    assert((backend.resultReads == 0 &&
            "poll must not fetch a timestamp until GL_QUERY_RESULT_AVAILABLE"));
    assert(ring.pending() == 1);
    for (const auto& item : backend.values) backend.ready.insert(item.first);
    const auto complete = ring.poll(backend);
    assert(complete.size() == 1);
    assert(complete[0].name == "source_scene_eye1");
    assert(complete[0].scene == "PEWTER_CITY/above" && complete[0].frame == 42);
    assert(complete[0].durationNs == 1);
    assert(ring.pending() == 0 && backend.resultReads == 2);
    ring.release(backend);
    assert((backend.destroyed.size() == 2 &&
            "shutdown must release both query objects for every allocated slot"));

    using PollRing = vrtelemetry::TimestampRing<4>;
    FakeTimestampBackend pollBackend;
    PollRing pollRing;
    for (uint64_t frame = 1; frame <= 4; ++frame) {
        assert(pollRing.begin(pollBackend, "scope", frame, "map/above"));
        pollRing.end(pollBackend);
    }
    assert(pollRing.poll(pollBackend, 2).empty());
    assert(pollBackend.availabilityChecks == 2 && pollBackend.resultReads == 0);
    for (const auto& item : pollBackend.values) pollBackend.ready.insert(item.first);
    const auto firstBatch = pollRing.poll(pollBackend, 2);
    const auto secondBatch = pollRing.poll(pollBackend, 2);
    assert(firstBatch.size() == 2 && secondBatch.size() == 2);
    assert(pollRing.pending() == 0 && pollBackend.resultReads == 8);
    pollRing.release(pollBackend);

    FakeTimestampBackend errorBackend;
    errorBackend.resultSucceeds = false;
    Ring errorRing;
    assert(errorRing.begin(errorBackend, "error", 7, "PEWTER_GYM/above"));
    errorRing.end(errorBackend);
    for (const auto& item : errorBackend.values) errorBackend.ready.insert(item.first);
    assert(errorRing.poll(errorBackend).empty());
    assert(errorRing.status() == Ring::QueryStatus::Error);
    assert(errorRing.errors() == 1 && errorRing.pending() == 0);
    errorRing.release(errorBackend);
    assert(errorBackend.destroyed.size() == 2);

    const auto observed = client(
        "drm-driver: msm\n"
        "drm-client-id: 417895\n"
        "drm-engine-gpu: 7949198183083 ns\n"
        "drm-cycles-gpu: 3651934164314\n"
        "drm-maxfreq-gpu: 903000000 Hz\n");
    assert(observed.key == "msm:no-pdev:417895");
    assert(observed.engineNs == 7949198183083ull);
    assert(observed.cycles == 3651934164314ull && observed.maxFreqHz == 903000000ull);
    vrtelemetry::DrmClientCounters invalid;
    assert((!vrtelemetry::parseDrmFdInfo(
        "drm-driver: msm\ndrm-client-id: 417895\ndrm-engine-gpu-ns: 99\n", &invalid) &&
        "the actual kernel key is drm-engine-gpu with the ns unit after its value"));

    auto sameClient = client(
        "drm-driver: msm\ndrm-client-id: 417895\n"
        "drm-engine-gpu: 800 ns\ndrm-cycles-gpu: 900\n");
    std::map<std::string, vrtelemetry::DrmClientCounters> counters;
    vrtelemetry::mergeDrmClient(counters, observed);
    vrtelemetry::mergeDrmClient(counters, sameClient);
    assert((counters.size() == 1 &&
            counters.begin()->second.engineNs == observed.engineNs &&
            "duplicate fds for one client must use a maximum, not add counters"));

    auto pdevClient = client(
        "drm-driver: msm\ndrm-pdev: 0000:00:02.0\ndrm-client-id: 51\n"
        "drm-engine-gpu: 600 ns\n");
    auto duplicatePdevClient = client(
        "drm-driver: alternate\ndrm-pdev: 0000:00:02.0\ndrm-client-id: 51\n"
        "drm-engine-gpu: 700 ns\n");
    assert(pdevClient.key == "pdev:0000:00:02.0:51");
    counters.clear();
    vrtelemetry::mergeDrmClient(counters, pdevClient);
    vrtelemetry::mergeDrmClient(counters, duplicatePdevClient);
    assert(counters.size() == 1 && counters.begin()->second.engineNs == 700);

    vrtelemetry::DrmCounterTracker tracker;
    counters.clear();
    counters.emplace(observed.key, observed);
    auto window = tracker.sample(counters, 1000000000ull);
    assert(window.status == "warming" && !window.busyAvailable);
    auto next = observed;
    next.engineNs += 500000000ull;
    next.cycles += 1000000ull;
    counters[next.key] = next;
    window = tracker.sample(counters, 1000000000ull);
    assert(window.status == "available" && window.busyAvailable);
    assert(window.busyNs == 500000000ull && window.cycles == 1000000ull);

    auto regressed = next;
    regressed.engineNs -= 300000000ull;
    counters[regressed.key] = regressed;
    window = tracker.sample(counters, 1000000000ull);
    assert(window.status == "warming" && window.regressions == 1);
    auto caughtUp = regressed;
    caughtUp.engineNs += 310000000ull;
    counters[caughtUp.key] = caughtUp;
    window = tracker.sample(counters, 1000000000ull);
    assert((window.status == "available" && window.busyNs == 10000000ull &&
            "temporary counter regressions must retain the old high-water mark"));

    auto cycleRegression = caughtUp;
    cycleRegression.engineNs += 100000000ull;
    cycleRegression.cycles -= 5000ull;
    counters[cycleRegression.key] = cycleRegression;
    window = tracker.sample(counters, 1000000000ull);
    assert(window.status == "partial" && window.regressions == 1
        && window.busyNs == 100000000ull && !window.cyclesAvailable);
    auto cycleCaughtUp = cycleRegression;
    cycleCaughtUp.engineNs += 100000000ull;
    cycleCaughtUp.cycles = caughtUp.cycles + 5000ull;
    counters[cycleCaughtUp.key] = cycleCaughtUp;
    window = tracker.sample(counters, 1000000000ull);
    assert(window.status == "available" && window.cycles == 5000ull);

    auto second = client(
        "drm-driver: msm\ndrm-client-id: 99\n"
        "drm-engine-gpu: 200 ns\n");
    counters[second.key] = second;
    window = tracker.sample(counters, 1000000000ull);
    assert(window.status == "partial" && window.addedClients == 1);
    counters.erase(second.key);
    window = tracker.sample(counters, 1000000000ull);
    assert(window.status == "partial" && window.removedClients == 1);
    assert(tracker.sample({}, 1000000000ull).status == "unavailable");
    return 0;
}
