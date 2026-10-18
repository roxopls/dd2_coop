#pragma once
#include <algorithm>
#include <cmath>

namespace motion_correction {
struct Step { float x = 0, z = 0; };
// Root-motion translation is in world axes in the measured DD2 callback.
// Never correct height here: gravity, jumping and terrain remain engine-owned.
inline Step step(double dx, double dz, double dt, double deadzone = 0.15,
        double gain = 3.0, double max_speed = 1.5) {
    if (!std::isfinite(dx) || !std::isfinite(dz) || !std::isfinite(dt) ||
            !std::isfinite(deadzone) || !std::isfinite(gain) || !std::isfinite(max_speed) ||
            dt <= 0 || gain <= 0 || max_speed <= 0 || deadzone < 0) return {};
    const double distance = std::hypot(dx, dz);
    if (!std::isfinite(distance) || distance <= deadzone) return {};
    dt = std::min(dt, 1.0 / 30.0); // no burst after a stall, pause or parked clone
    const double amount = std::min({distance * -std::expm1(-gain * dt),
        max_speed * dt, distance - deadzone});
    return {static_cast<float>(dx / distance * amount),
        static_cast<float>(dz / distance * amount)};
}
}
