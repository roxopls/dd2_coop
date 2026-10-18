// Exercise the real receiver/playback path with fake input memory, no game/Steam.
#include "../src/net_sync.cpp"
#include <iostream>
#include <stdexcept>

struct TestInput {
    uint64_t on = 0, old = 0, trigger = 0, release = 0, repeat = 0;
    uint32_t pad = 0, pad_down = 0, pad_up = 0;
    float stick[2] = {};
};
void check(bool ok, const char* reason) { if (!ok) throw std::runtime_error(reason); }

namespace {
struct MotionActor { bool ground = true, jumping = false, carrying = false, caught = false; };
int motion_warps = 0;
REFrameworkMethodHandle motion_method(uintptr_t id) { return reinterpret_cast<REFrameworkMethodHandle>(id); }
REFrameworkResult motion_invoke(REFrameworkMethodHandle method, void* self, void**, unsigned int,
        void* out, unsigned int) {
    auto& actor = *static_cast<MotionActor*>(self);
    switch (reinterpret_cast<uintptr_t>(method)) {
    case 1: std::memcpy(out, &actor.ground, sizeof(bool)); break;
    case 2: std::memcpy(out, &actor.jumping, sizeof(bool)); break;
    case 3: { void* p = &actor.carrying; std::memcpy(out, &p, sizeof(p)); break; }
    case 4: { void* p = &actor.caught; std::memcpy(out, &p, sizeof(p)); break; }
    case 5: std::memcpy(out, self, sizeof(bool)); break;
    case 6: { double p[3]{}; std::memcpy(out, p, sizeof(p)); break; }
    case 7: { float q[4]{0, 0, 0, 1}; std::memcpy(out, q, sizeof(q)); break; }
    case 8: ++motion_warps; break;
    default: throw std::runtime_error("unexpected engine invocation");
    }
    return REFRAMEWORK_ERROR_NONE;
}
}
int main() try {
    using namespace net_sync;
    g_lua_ready = true;
    auto field = [](const char* name, uint32_t offset, uint32_t size) {
        g_fields.push_back({name, offset, size, false, input_safety::classify(name)});
        g_payload_size += size;
    };
    field("ButtonOnFlags", offsetof(TestInput, on), 8);
    field("OldButtonOnFlags", offsetof(TestInput, old), 8);
    field("ButtonTriggerFlags", offsetof(TestInput, trigger), 8);
    field("ButtonReleaseFlags", offsetof(TestInput, release), 8);
    field("ButtonRepeatFlags", offsetof(TestInput, repeat), 8);
    field("PadButton", offsetof(TestInput, pad), 4);
    field("PadButtonDown", offsetof(TestInput, pad_down), 4);
    field("PadButtonUp", offsetof(TestInput, pad_up), 4);
    field("_AxisL", offsetof(TestInput, stick), 8);
    TestInput destination;
    destination.on = 3;
    destination.stick[0] = 1;
    g_slot_count = 1;
    Slot& s0 = g_slots[0];
    auto apply = [&]() { apply_to(s0, reinterpret_cast<uintptr_t>(&destination)); };
    apply();
    check(destination.on == 0 && destination.release == 3 && destination.stick[0] == 0,
        "waiting for first packet must neutralize local controller state");
    apply();
    check(destination.release == 0, "waiting release must not repeat");
    TestInput sender;
    sender.on = 7; sender.trigger = 4; sender.repeat = 2;
    sender.pad = 3; sender.pad_down = 1; sender.stick[0] = 0.75f;
    uint32_t sequence = 0, stamp = 0;
    auto receive = [&]() {
        PacketHeader header{};
        header.magic = kMagic; header.version = kVersion;
        header.seq = sequence++; header.payload_size = g_payload_size; header.t_ms = stamp;
        header.field_count = static_cast<uint16_t>(g_fields.size());
        std::vector<uint8_t> packet(sizeof(header) + g_payload_size);
        std::memcpy(packet.data(), &header, sizeof(header));
        auto* cursor = packet.data() + sizeof(header);
        for (const auto& f : g_fields) {
            std::memcpy(cursor, reinterpret_cast<const uint8_t*>(&sender) + f.offset, f.size);
            cursor += f.size;
        }
        handle_packet(s0, packet.data(), static_cast<int>(packet.size()));
    };
    g_cfg.mode = "p2p"; g_cfg.jitter = 1;
    receive(); advance_playback(s0); apply();
    check(destination.on == 7 && destination.trigger == 4 && destination.pad_down == 1,
        "fresh packet must preserve button transitions");
    apply();
    check(destination.on == 7 && destination.old == 7 && destination.trigger == 0 &&
        destination.repeat == 0 && destination.pad_down == 0 && destination.stick[0] == 0.75f,
        "repeated input callback must not replay packet edges");
    advance_playback(s0); apply();
    check(destination.trigger == 0 && destination.on == 7,
        "brief underflow preserves hold without new edges");
    receive(); // leave an old packet queued, then simulate a stalled stream
    s0.watchdog.received(GetTickCount64() - input_safety::Watchdog::timeout_ms);
    advance_playback(s0); apply();
    check(s0.buffer.empty() && !s0.playing && !s0.remote_pose.valid && s0.timeouts == 1,
        "timeout must discard old playback and pose");
    check(destination.on == 0 && destination.pad == 0 && destination.release == 7 &&
        destination.pad_up == 3 && destination.stick[0] == 0, "timeout releases applied input");
    advance_playback(s0); apply();
    check(destination.release == 0 && destination.pad_up == 0 && s0.timeouts == 1,
        "neutral frames must not repeat release or timeout count");
    g_cfg.jitter = 2;
    receive(); advance_playback(s0); apply();
    check(!s0.playing && destination.on == 0, "recovery must refill jitter buffer");
    receive(); advance_playback(s0); apply();
    check(s0.playing && !s0.watchdog.expired() && destination.trigger == 4,
        "fresh input resumes after recovery");
    // playback on the sender's clock
    s0.buffer.clear(); s0.playing = false; s0.fresh_input = false;
    s0.watchdog.received(GetTickCount64());
    g_cfg.jitter = 1;
    stamp = 1000; sender = TestInput{}; sender.on = 7; sender.trigger = 4;
    receive(); advance_playback(s0); apply();
    check(s0.playing && destination.trigger == 4, "timed playback starts on first packet");
    sender = TestInput{}; sender.on = 8; sender.trigger = 8; receive();          // faster sender:
    sender = TestInput{}; sender.release = 8; receive();                          // two due packets
    advance_playback(s0); apply();
    check(destination.trigger == 8 && destination.release == 8 && destination.on == 0 && s0.buffer.empty(),
        "packets due in one frame merge edges and keep newest held state");
    stamp = 1000 + 60000; sender = TestInput{}; sender.on = 1; sender.trigger = 1; receive();
    advance_playback(s0); apply();
    check(destination.trigger == 0 && destination.release == 0 && s0.buffer.size() == 1,
        "packet from the sender's future waits; held frame repeats no edges");
    std::strcpy(g_instance_id, "test_process");
    g_lua_epoch = 0;
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":0,\"save_lock\":false}");
    check(!g_save_locked, "confirmed single-player session can save");
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":0,\"save_lock\":true}");
    check(g_save_locked, "live clone locks saving");
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":0,\"save_lock\":false");
    check(g_save_locked, "partial file cannot unlock saving");
    update_save_guard("{\"instance\":\"old_process\",\"lua_epoch\":0,\"save_lock\":false}");
    check(g_save_locked, "previous process cannot unlock saving");
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":\"bad\",\"save_lock\":false}");
    check(g_save_locked, "malformed reset epoch cannot unlock saving");
    g_dir = "?:/"; // make status/file reads fail without touching a real file
    g_steam.me = 1;
    on_lua_destroyed(nullptr);
    check(g_save_locked && !g_lua_ready && g_lua_epoch == 1 && !s0.playing,
        "native protection and playback must survive Lua destruction");
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":0,\"save_lock\":false}");
    check(g_save_locked, "pre-reset file cannot unlock saving");
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":1,\"save_lock\":false}");
    check(!g_save_locked, "new Lua verification can unlock clean session");
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":1,\"save_lock\":false,\"force_lock\":true}");
    check(g_save_locked, "extra clones force the save lock");
    update_save_guard("{\"instance\":\"test_process\",\"lua_epoch\":1,\"save_lock\":false}");
    check(pre_save(0, nullptr, nullptr, 0) == REFRAMEWORK_HOOK_SKIP_ORIGINAL,
        "missing configuration must block native save");
    void* result = reinterpret_cast<void*>(1);
    post_save(&result, nullptr, 0);
    check(result == nullptr, "blocked save must return false");
    // N jogadores: cada slot tem a própria fila; o hook aplica o input na cópia certa
    {
        PeerCfg peers[3];
        check(parse_peers("{\"peer_count\":2,\"peer0\":\"11\",\"clone0\":100,\"peer1\":\"22\",\"clone1\":200,"
            "\"clone_ch1\":7}", peers) == 2 && peers[0].id == 11 && peers[0].clone == 100 && peers[1].id == 22 &&
            peers[1].clone == 200 && peers[1].clone_ch == 7, "indexed peers parse");
        check(parse_peers("{\"peer\":\"33\",\"clone\":300,\"clone_xf\":5}", peers) == 1 && peers[0].id == 33 &&
            peers[0].clone == 300 && peers[0].clone_xf == 5, "legacy single peer parse");
        check(parse_peers("{\"peer_count\":9}", peers) == kMaxSlots, "peer count capped");
        g_lua_ready = true;
        g_cfg.jitter = 1;
        g_cfg.mode = "p2p";
        g_slot_count = 2;
        g_slots[0] = Slot{};
        g_slots[1] = Slot{};
        TestInput a, b;
        g_slots[0].clone = reinterpret_cast<uintptr_t>(&a);
        g_slots[1].clone = reinterpret_cast<uintptr_t>(&b);
        auto send_to = [&](Slot& s, uint64_t on) {
            PacketHeader header{};
            header.magic = kMagic; header.version = kVersion; header.payload_size = g_payload_size;
            header.field_count = static_cast<uint16_t>(g_fields.size());
            TestInput t{};
            t.on = on;
            std::vector<uint8_t> packet(sizeof(header) + g_payload_size);
            std::memcpy(packet.data(), &header, sizeof(header));
            auto* cursor = packet.data() + sizeof(header);
            for (const auto& f : g_fields) {
                std::memcpy(cursor, reinterpret_cast<const uint8_t*>(&t) + f.offset, f.size);
                cursor += f.size;
            }
            handle_packet(s, packet.data(), static_cast<int>(packet.size()));
        };
        send_to(g_slots[0], 5);
        send_to(g_slots[1], 9);
        advance_playback(g_slots[0]);
        advance_playback(g_slots[1]);
        void* argv_a[2] = { nullptr, &a };
        void* argv_b[2] = { nullptr, &b };
        check(pre_update(2, argv_a, nullptr, 0) == REFRAMEWORK_HOOK_SKIP_ORIGINAL &&
            pre_update(2, argv_b, nullptr, 0) == REFRAMEWORK_HOOK_SKIP_ORIGINAL, "both clones are driven");
        check(a.on == 5 && b.on == 9, "each clone gets its own player input");
        check(g_slots[0].received == 1 && g_slots[1].received == 1 && g_slots[0].applied == 1 &&
            g_slots[1].applied == 1, "per-slot counters");
    }
    // Exercise the actual root hook and warp policy with a small engine boundary mock.
    {
        REFrameworkTDBMethod methods{};
        methods.invoke = motion_invoke;
        REFrameworkSDKData sdk{};
        sdk.method = &methods;
        g_sdk = &sdk;
        g_motion.ready = true;
        g_motion.ground = motion_method(1); g_motion.jumping = motion_method(2);
        g_motion.catcher = motion_method(3); g_motion.caught = motion_method(4);
        g_motion.catch_active = g_motion.caught_active = motion_method(5);
        g_cam.univ_get = motion_method(6); g_cam.rotation = motion_method(7); g_warp = motion_method(8);
        g_lua_ready = true; g_cfg.mode = "p2p"; g_cfg.smooth_correction = true;
        g_slot_count = 1; g_slots[0] = Slot{};
        auto& s = g_slots[0];
        MotionActor actor;
        s.clone_ch = s.clone_xf = reinterpret_cast<uintptr_t>(&actor);
        s.playing = s.placed = true;
        s.current.pose = Pose{2, 0, 0, 0, true};
        correct_clone(s);
        check(s.correction_x == 2 && motion_warps == 0, "ordinary drift schedules motion, never warp");
        float root[3]{0, 0.2f, 0};
        void* argv[4]{nullptr, &actor, root, nullptr};
        Sleep(20); // let the real plugin clock cover a full simulated frame
        s.last_root_ms = now_ms() - 16;
        pre_root_motion(4, argv, nullptr, 0);
        check(root[0] > 0 && root[0] <= 0.050001f && root[1] == 0.2f && root[2] == 0,
            "root hook adds bounded horizontal movement and preserves jump height");
        root[0] = 0;
        actor.caught = true; // attachment can begin after correction was scheduled
        s.last_root_ms = now_ms() - 16;
        pre_root_motion(4, argv, nullptr, 0);
        check(root[0] == 0, "root hook rechecks catch state before applying correction");
        s.current.pose.x = 100; s.placed = false;
        for (auto which : {0, 1, 2, 3}) {
            actor = MotionActor{};
            if (which == 0) actor.ground = false;
            if (which == 1) actor.jumping = true;
            if (which == 2) actor.carrying = true;
            if (which == 3) actor.caught = true;
            correct_clone(s);
            check(motion_warps == 0 && s.correction_x == 0,
                "no warp or smooth correction while airborne, jumping, carrying or caught");
        }
        actor = MotionActor{};
        s.current.fields.resize(g_payload_size);
        size_t offset = 0;
        for (auto& f : g_fields) {
            if (std::strcmp(f.name, "ButtonTriggerFlags") == 0) {
                uint64_t jump = 8; std::memcpy(s.current.fields.data() + offset, &jump, f.size);
            }
            offset += f.size;
        }
        s.fresh_input = true;
        correct_clone(s);
        check(motion_warps == 0 && s.jump_grace_until > GetTickCount64(),
            "incoming jump edge suppresses warp before engine jump state changes");
        s.fresh_input = false; s.jump_grace_until = 0;
        correct_clone(s); correct_clone(s);
        check(motion_warps == 1 && s.placed, "initial/far placement warps once and uses elapsed-time cooldown");
        root[0] = 0; s.correction_x = 2; s.last_root_ms = now_ms() - 16;
        g_cfg.mode = "eco";
        pre_root_motion(4, argv, nullptr, 0);
        check(root[0] == 0, "ordinary echo does not enable position correction");
        g_cfg.echo_correction = true;
        s.echo_offset = Pose{};
        s.current.pose = Pose{2, 0, 0, 0, true};
        correct_clone(s);
        check(s.echo_offset.x == -2 && s.correction_x == 0 && motion_warps == 1,
            "corrected echo anchors its offset without overlapping the original");
        s.current.pose.x = 3;
        correct_clone(s);
        check(s.correction_x == 1 && motion_warps == 1, "corrected echo follows motion relative to its anchor");
        g_cfg.echo_correction = false;
        g_cfg.mode = "p2p";
        MotionActor original;
        argv[1] = &original;
        pre_root_motion(4, argv, nullptr, 0);
        check(root[0] == 0, "local player and unrelated actors are never corrected");
        argv[1] = &actor;
        s.watchdog.received(GetTickCount64() - 600); s.watchdog.expire(GetTickCount64());
        pre_root_motion(4, argv, nullptr, 0);
        check(root[0] == 0, "expired input cannot apply a pending movement correction");
        s.reset_playback();
        check(s.correction_x == 0 && s.last_root_ms == 0 && s.jump_grace_until == 0,
            "session reset discards correction and timing state");
        g_sdk = nullptr;
    }
    std::cout << "real playback, N players, native save guard and root motion: all checks passed\n";
} catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
}
