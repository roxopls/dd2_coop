#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>

// Playback policy independent of REFramework and Steam for offline tests.
namespace input_safety {
enum class Mode { Fresh, Hold, Neutral };
enum class Kind { Held, PreviousButtons, Edge, ButtonRelease, PadRelease };
inline Kind classify(const char* name) {
    if (std::strcmp(name, "OldButtonOnFlags") == 0) return Kind::PreviousButtons;
    if (std::strcmp(name, "ButtonReleaseFlags") == 0) return Kind::ButtonRelease;
    if (std::strcmp(name, "PadButtonUp") == 0) return Kind::PadRelease;
    for (const char* edge : { "ButtonTriggerFlags", "ButtonRepeatFlags", "PadButtonDown",
            "PadButtonRepeat", "<IsMouseMovedInFrame>k__BackingField",
            "<IsPadAxisRMovedInFrame>k__BackingField" }) {
        if (std::strcmp(name, edge) == 0) return Kind::Edge;
    }
    return Kind::Held;
}
class Watchdog {
public:
    static constexpr uint64_t timeout_ms = 500;
    void received(uint64_t now) { last_ = now; seen_ = true; expired_ = false; }
    bool expire(uint64_t now) {
        if (!seen_ || expired_ || now - last_ < timeout_ms) return false;
        expired_ = true;
        return true;
    }
    bool seen() const { return seen_; }
    bool expired() const { return expired_; }
    uint64_t age(uint64_t now) const { return now - last_; }
private:
    uint64_t last_ = 0;
    bool seen_ = false, expired_ = false;
};
inline void write_flags(void* dst, std::size_t size, uint64_t flags) {
    std::memset(dst, 0, size);
    std::memcpy(dst, &flags, size < sizeof(flags) ? size : sizeof(flags));
}
// Joins a newer packet into one not yet applied (receiver slower than sender):
// edges and releases accumulate (OR) so no press is lost; held state is the newest;
// OldButtonOnFlags stays from the first packet (state before the merged span).
inline void merge_field(Kind kind, uint8_t* acc, const uint8_t* newer, std::size_t size) {
    if (kind == Kind::Edge || kind == Kind::ButtonRelease || kind == Kind::PadRelease) {
        for (std::size_t i = 0; i < size; ++i) acc[i] |= newer[i];
    } else if (kind != Kind::PreviousButtons) {
        std::memcpy(acc, newer, size);
    }
}
inline void apply_field(Kind kind, void* dst, const void* source, std::size_t size,
        Mode mode, uint64_t previous_buttons, uint64_t previous_pad) {
    if (mode == Mode::Fresh) { std::memcpy(dst, source, size); return; }
    if (kind == Kind::PreviousButtons) {
        write_flags(dst, size, previous_buttons);
    } else if (mode == Mode::Neutral) {
        const uint64_t released = kind == Kind::ButtonRelease ? previous_buttons :
            kind == Kind::PadRelease ? previous_pad : 0;
        write_flags(dst, size, released);
    } else if (kind == Kind::Edge || kind == Kind::ButtonRelease || kind == Kind::PadRelease) {
        std::memset(dst, 0, size);
    } else {
        std::memcpy(dst, source, size);
    }
}
} // namespace input_safety
