#include "../src/motion_correction.hpp"
#include <iostream>
#include <limits>
#include <stdexcept>

void require(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }
int main() {
    using motion_correction::step;
    auto s = step(3, 4, 1.0 / 60);
    require(std::abs(std::hypot(s.x, s.z) - 1.5 / 60) < 1e-7, "cap correction speed");
    require(std::abs(s.x / s.z - 0.75) < 1e-6, "preserve error direction");
    s = step(3, 4, 5);
    require(std::hypot(s.x, s.z) <= 0.050001, "no catch-up teleport after a five-second stall");
    s = step(0.151, 0, 1.0 / 30);
    require(std::abs(s.x - 0.001) < 1e-8, "do not overshoot the deadzone");
    require(step(0.1, 0.1, 0.02).x == 0, "ignore sub-deadzone drift");
    for (double dt : {0.0, -1.0, std::numeric_limits<double>::quiet_NaN()})
        require(step(1, 0, dt).x == 0, "invalid frame interval must not move actor");
    require(step(std::numeric_limits<double>::infinity(), 0, 0.02).x == 0, "reject invalid pose");
    for (int fps : {30, 60, 144}) {
        double error = 1;
        for (int i = 0; i < fps / 2; ++i)
            error -= step(error, 0, 1.0 / fps, 0, 3, 100).x;
        require(std::abs(error - std::exp(-1.5)) < 1e-6, "half-second convergence independent of FPS");
    }
    std::cout << "time-based planar correction: all checks passed\n";
}
