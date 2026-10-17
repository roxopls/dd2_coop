#include "input_safety.hpp"
#include <iostream>
#include <stdexcept>
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() {
    using namespace input_safety;
    Watchdog w;
    check(!w.expire(10000), "waiting is not a disconnect");
    w.received(10000);
    check(!w.expire(10499), "brief jitter must not timeout");
    check(w.expire(10500) && w.expired(), "timeout in milliseconds");
    check(!w.expire(11000), "one timeout per outage");
    w.received(12000);
    check(w.seen() && !w.expired() && w.age(12001) == 1, "packet recovers watchdog");
    check(w.expire(12500), "second outage detected");
    const uint64_t packet = 7;
    uint64_t dst = 0;
    for (const char* name : { "ButtonTriggerFlags", "ButtonReleaseFlags", "ButtonRepeatFlags",
            "PadButtonDown", "PadButtonUp", "PadButtonRepeat",
            "<IsMouseMovedInFrame>k__BackingField", "<IsPadAxisRMovedInFrame>k__BackingField" }) {
        auto kind = classify(name);
        apply_field(kind, &dst, &packet, sizeof(dst), Mode::Fresh, 0, 0);
        check(dst == packet, "fresh packet preserves edges");
        apply_field(kind, &dst, &packet, sizeof(dst), Mode::Hold, 7, 3);
        check(dst == 0, "held packet must not replay edge");
    }
    apply_field(classify("ButtonOnFlags"), &dst, &packet, sizeof(dst), Mode::Hold, 7, 3);
    check(dst == 7, "hold preserves pressed buttons");
    apply_field(classify("OldButtonOnFlags"), &dst, &packet, sizeof(dst), Mode::Hold, 9, 3);
    check(dst == 9, "old buttons match last applied state");
    uint64_t on = 7, old = 0, release = 0;
    uint32_t pad = 3, pad_up = 0;
    for (int tick = 0; tick < 3; ++tick) {
        const auto prior = on;
        const auto prior_pad = pad;
        apply_field(Kind::Held, &on, nullptr, sizeof(on), Mode::Neutral, prior, prior_pad);
        apply_field(Kind::PreviousButtons, &old, nullptr, sizeof(old), Mode::Neutral, prior, prior_pad);
        apply_field(Kind::ButtonRelease, &release, nullptr, sizeof(release), Mode::Neutral, prior, prior_pad);
        apply_field(Kind::Held, &pad, nullptr, sizeof(pad), Mode::Neutral, prior, prior_pad);
        apply_field(Kind::PadRelease, &pad_up, nullptr, sizeof(pad_up), Mode::Neutral, prior, prior_pad);
        check(on == 0 && pad == 0, "timeout clears buttons");
        check(release == (tick == 0 ? 7u : 0u), "release exactly once");
        check(old == release && pad_up == (tick == 0 ? 3u : 0u), "timeout release mapping");
    }
    float stick[2] = { 0.5f, -1.0f }, output[2] = {};
    apply_field(classify("_AxisL"), output, stick, sizeof(stick), Mode::Hold, 0, 0);
    check(output[0] == 0.5f && output[1] == -1.0f, "hold preserves analog");
    apply_field(classify("_AxisL"), output, nullptr, sizeof(stick), Mode::Neutral, 0, 0);
    check(output[0] == 0 && output[1] == 0, "timeout clears analog");
    for (uint64_t step : { 8u, 16u, 33u }) {
        Watchdog rate;
        rate.received(1000);
        uint64_t first = 0;
        for (uint64_t now = 1000; now < 1700; now += step) if (rate.expire(now)) first = now;
        check(first >= 1500 && first < 1500 + step, "timeout independent of FPS");
    }
    std::cout << "input safety: all checks passed\n";
}
