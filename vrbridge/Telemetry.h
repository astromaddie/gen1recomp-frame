#pragma once

#include <array>
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace vrtelemetry {

class ForcedRenderWindow {
public:
    static constexpr uint64_t kMaxDurationSeconds = 120;

    void arm(bool telemetryEnabled, bool requested, uint64_t startNs,
             uint64_t durationSeconds) {
        m_requested = telemetryEnabled && requested;
        m_armed = false;
        m_expired = false;
        m_startedAtNs = startNs;
        m_deadlineNs = startNs;
        m_durationNs = 0;
        if (!m_requested) return;
        if (durationSeconds == 0) {
            m_expired = true;
            return;
        }
        durationSeconds = std::min(durationSeconds, kMaxDurationSeconds);
        m_durationNs = durationSeconds * 1000000000ull;
        m_deadlineNs = startNs > UINT64_MAX - m_durationNs
            ? UINT64_MAX : startNs + m_durationNs;
        m_armed = true;
    }

    bool active(uint64_t nowNs) {
        if (!m_armed) return false;
        if (nowNs >= m_deadlineNs) {
            m_armed = false;
            m_expired = true;
            return false;
        }
        return true;
    }

    bool allows(bool runtimeShouldRender, uint64_t nowNs) {
        return runtimeShouldRender || active(nowNs);
    }

    bool overrides(bool runtimeShouldRender, uint64_t nowNs) {
        return !runtimeShouldRender && active(nowNs);
    }

    bool requested() const { return m_requested; }
    bool expired() const { return m_expired; }
    uint64_t startedAtNs() const { return m_startedAtNs; }
    uint64_t deadlineNs() const { return m_deadlineNs; }
    uint64_t durationNs() const { return m_durationNs; }

private:
    bool m_requested = false;
    bool m_armed = false;
    bool m_expired = false;
    uint64_t m_startedAtNs = 0;
    uint64_t m_deadlineNs = 0;
    uint64_t m_durationNs = 0;
};

struct TimestampResult {
    std::string name;
    std::string scene;
    uint64_t frame = 0;
    uint64_t durationNs = 0;
};

struct DrmClientCounters {
    std::string key;
    std::string driver;
    uint64_t clientId = 0;
    uint64_t engineNs = 0;
    uint64_t cycles = 0;
    uint64_t maxFreqHz = 0;
    bool hasEngine = false;
    bool hasCycles = false;
};

struct DrmClientDelta {
    DrmClientCounters counters;
    uint64_t busyNs = 0;
    uint64_t cycles = 0;
    bool comparable = false;
    bool cyclesAvailable = false;
};

struct DrmCounterWindow {
    std::string status = "unavailable";
    uint64_t busyNs = 0;
    uint64_t cycles = 0;
    uint64_t maxFreqHz = 0;
    uint64_t addedClients = 0;
    uint64_t removedClients = 0;
    uint64_t regressions = 0;
    bool busyAvailable = false;
    bool cyclesAvailable = false;
    bool maxFreqAvailable = false;
    std::vector<DrmClientDelta> clients;
};

inline bool parseUnsignedField(const std::string& text, uint64_t* value) {
    const char* begin = text.c_str();
    while (*begin == ' ' || *begin == '\t') ++begin;
    if (*begin < '0' || *begin > '9') return false;
    errno = 0;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(begin, &end, 10);
    if (errno || end == begin) return false;
    *value = static_cast<uint64_t>(parsed);
    return true;
}

inline bool parseDrmFdInfo(const std::string& text, DrmClientCounters* result) {
    DrmClientCounters parsed;
    std::string pdev;
    bool hasClientId = false;
    std::istringstream input(text);
    std::string line;
    while (std::getline(input, line)) {
        const size_t colon = line.find(':');
        if (colon == std::string::npos) continue;
        const std::string field = line.substr(0, colon);
        const std::string value = line.substr(colon + 1);
        if (field == "drm-driver") {
            std::istringstream item(value);
            item >> parsed.driver;
        } else if (field == "drm-pdev") {
            std::istringstream item(value);
            item >> pdev;
        } else if (field == "drm-client-id") {
            hasClientId = parseUnsignedField(value, &parsed.clientId);
        } else if (field == "drm-engine-gpu") {
            parsed.hasEngine = parseUnsignedField(value, &parsed.engineNs);
        } else if (field == "drm-cycles-gpu") {
            parsed.hasCycles = parseUnsignedField(value, &parsed.cycles);
        } else if (field == "drm-maxfreq-gpu") {
            (void)parseUnsignedField(value, &parsed.maxFreqHz);
        }
    }
    if (parsed.driver.empty() || !hasClientId || !parsed.hasEngine) return false;
    parsed.key = pdev.empty()
        ? parsed.driver + ":no-pdev:" + std::to_string(parsed.clientId)
        : "pdev:" + pdev + ":" + std::to_string(parsed.clientId);
    *result = std::move(parsed);
    return true;
}

inline void mergeDrmClient(std::map<std::string, DrmClientCounters>& clients,
                           const DrmClientCounters& current) {
    auto inserted = clients.emplace(current.key, current);
    if (!inserted.second) {
        // Duplicate fdinfo entries for one DRM client describe one counter.
        DrmClientCounters& known = inserted.first->second;
        known.engineNs = std::max(known.engineNs, current.engineNs);
        known.cycles = std::max(known.cycles, current.cycles);
        known.maxFreqHz = std::max(known.maxFreqHz, current.maxFreqHz);
        known.hasCycles = known.hasCycles || current.hasCycles;
    }
}

class DrmCounterTracker {
public:
    DrmCounterWindow sample(
        const std::map<std::string, DrmClientCounters>& current,
        uint64_t wallNs) {
        DrmCounterWindow result;
        if (current.empty()) {
            result.status = "unavailable";
            result.removedClients = m_previous.size();
            m_previous.clear();
            return result;
        }

        bool complete = true;
        size_t comparable = 0;
        std::map<std::string, DrmClientCounters> next;
        for (const auto& entry : current) {
            const DrmClientCounters& now = entry.second;
            DrmClientCounters highWater = now;
            result.maxFreqHz = std::max(result.maxFreqHz, now.maxFreqHz);
            DrmClientDelta delta;
            delta.counters = now;
            if (now.maxFreqHz) result.maxFreqAvailable = true;
            const auto old = m_previous.find(entry.first);
            if (old == m_previous.end()) {
                ++result.addedClients;
                complete = false;
            } else {
                bool regressed = false;
                if (now.engineNs < old->second.engineNs) {
                    regressed = true;
                    highWater.engineNs = old->second.engineNs;
                    complete = false;
                } else {
                    delta.busyNs = now.engineNs - old->second.engineNs;
                    result.busyNs += delta.busyNs;
                    delta.comparable = true;
                    ++comparable;
                }
                if (now.hasCycles && old->second.hasCycles) {
                    if (now.cycles >= old->second.cycles) {
                        delta.cycles = now.cycles - old->second.cycles;
                        delta.cyclesAvailable = true;
                        result.cyclesAvailable = true;
                        result.cycles += delta.cycles;
                        highWater.cycles = now.cycles;
                    } else {
                        regressed = true;
                        highWater.cycles = old->second.cycles;
                        complete = false;
                    }
                }
                if (regressed) ++result.regressions;
            }
            delta.counters = now;
            result.clients.push_back(delta);
            next.emplace(entry.first, std::move(highWater));
        }
        for (const auto& old : m_previous) {
            if (current.find(old.first) == current.end()) {
                ++result.removedClients;
                complete = false;
            }
        }
        m_previous = std::move(next);
        if (result.addedClients || result.removedClients || result.regressions)
            result.status = comparable && wallNs ? "partial" : "warming";
        else if (!comparable || wallNs == 0)
            result.status = "warming";
        else
            result.status = complete ? "available" : "partial";
        result.busyAvailable = comparable > 0 && wallNs > 0;
        return result;
    }

    void clear() { m_previous.clear(); }

private:
    std::map<std::string, DrmClientCounters> m_previous;
};

class TimestampBackend {
public:
    virtual ~TimestampBackend() = default;
    virtual bool supported() = 0;
    virtual uint32_t create() = 0;
    virtual void timestamp(uint32_t query) = 0;
    virtual bool available(uint32_t query) = 0;
    virtual bool result(uint32_t query, uint64_t* value) = 0;
    virtual void destroy(uint32_t query) = 0;
};

// A bounded, nonblocking timer-query ring. Query results are never fetched
// until both timestamps report available. Metadata belongs to issue time,
// since completion can arrive after the player has changed scenes.
template <size_t Capacity = 64>
class TimestampRing {
public:
    enum class QueryStatus { Unknown, Available, Unsupported, Error };

    bool probe(TimestampBackend& backend) {
        if (m_status == QueryStatus::Unknown)
            m_status = backend.supported() ? QueryStatus::Available : QueryStatus::Unsupported;
        return m_status == QueryStatus::Available;
    }

    bool begin(TimestampBackend& backend, const char* name, uint64_t frame,
               const char* scene) {
        if (!probe(backend)) return false;

        size_t index = Capacity;
        for (size_t i = 0; i < Capacity; ++i) {
            if (!m_slots[i].pending && !m_slots[i].recording) {
                index = i;
                break;
            }
        }
        if (index == Capacity) {
            ++m_dropped;
            return false;
        }

        Slot& slot = m_slots[index];
        if (!slot.startQuery) slot.startQuery = backend.create();
        if (!slot.endQuery) slot.endQuery = backend.create();
        if (!slot.startQuery || !slot.endQuery) {
            ++m_errors;
            m_status = QueryStatus::Error;
            return false;
        }
        slot.name = name ? name : "unnamed";
        slot.scene = scene ? scene : "unknown";
        slot.frame = frame;
        slot.recording = true;
        backend.timestamp(slot.startQuery);
        m_active[m_activeCount++] = index;
        m_status = QueryStatus::Available;
        return true;
    }

    void end(TimestampBackend& backend) {
        if (m_activeCount == 0) return;
        Slot& slot = m_slots[m_active[--m_activeCount]];
        backend.timestamp(slot.endQuery);
        slot.recording = false;
        slot.pending = true;
    }

    std::vector<TimestampResult> poll(TimestampBackend& backend,
                                      size_t maxChecks = Capacity) {
        std::vector<TimestampResult> ready;
        if (m_status == QueryStatus::Unsupported || m_status == QueryStatus::Error)
            return ready;
        size_t checked = 0;
        size_t scanned = 0;
        for (; scanned < Capacity && checked < maxChecks; ++scanned) {
            Slot& slot = m_slots[(m_nextPoll + scanned) % Capacity];
            if (!slot.pending) continue;
            ++checked;
            // The result access below may block; test both query objects first.
            if (!backend.available(slot.startQuery) ||
                !backend.available(slot.endQuery)) {
                continue;
            }
            uint64_t start = 0, endTime = 0;
            if (!backend.result(slot.startQuery, &start) ||
                !backend.result(slot.endQuery, &endTime) || endTime < start) {
                ++m_errors;
                m_status = QueryStatus::Error;
                slot.pending = false;
                continue;
            }
            ready.push_back({slot.name, slot.scene, slot.frame, endTime - start});
            slot.pending = false;
        }
        m_nextPoll = (m_nextPoll + scanned) % Capacity;
        return ready;
    }

    void release(TimestampBackend& backend) {
        m_activeCount = 0;
        for (Slot& slot : m_slots) {
            if (slot.startQuery) backend.destroy(slot.startQuery);
            if (slot.endQuery) backend.destroy(slot.endQuery);
            slot = Slot{};
        }
        m_status = QueryStatus::Unknown;
        m_dropped = 0;
        m_errors = 0;
        m_nextPoll = 0;
    }

    void abandon() {
        // The owning GL context is already gone, so its query objects have
        // been reclaimed by the driver. Drop names without issuing GL calls.
        for (Slot& slot : m_slots) slot = Slot{};
        m_activeCount = 0;
        m_status = QueryStatus::Unknown;
        m_dropped = 0;
        m_errors = 0;
        m_nextPoll = 0;
    }

    uint64_t pending() const {
        uint64_t count = 0;
        for (const Slot& slot : m_slots) if (slot.pending) ++count;
        return count;
    }
    uint64_t dropped() const { return m_dropped; }
    uint64_t errors() const { return m_errors; }
    QueryStatus status() const { return m_status; }
    void resetCounters() {
        m_dropped = 0;
        m_errors = 0;
    }
    void noteError() { ++m_errors; }
    void cancelActive() {
        while (m_activeCount > 0) {
            m_slots[m_active[--m_activeCount]].recording = false;
            ++m_errors;
        }
    }

private:
    struct Slot {
        uint32_t startQuery = 0;
        uint32_t endQuery = 0;
        uint64_t frame = 0;
        std::string name;
        std::string scene;
        bool recording = false;
        bool pending = false;
    };

    std::array<Slot, Capacity> m_slots{};
    std::array<size_t, Capacity> m_active{};
    size_t m_activeCount = 0;
    size_t m_nextPoll = 0;
    uint64_t m_dropped = 0;
    uint64_t m_errors = 0;
    QueryStatus m_status = QueryStatus::Unknown;
};

} // namespace vrtelemetry
