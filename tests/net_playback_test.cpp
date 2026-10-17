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
int main() {
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
    std::cout << "real playback, N players and native save guard: all checks passed\n";
}
