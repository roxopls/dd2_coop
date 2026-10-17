# DD2 Co-op

Co-op online para Dragon's Dogma 2: até 4 jogadores por enquanto, cada um com o
seu próprio personagem, via rede P2P da Steam. O host (quem cria a sessão) é a
autoridade do mundo: horário, clima, quests, inimigos e NPCs.

Em desenvolvimento. Use por sua conta e risco.

## Como funciona

- **Plugin nativo** (`src/*.cpp`, REFramework plugin API): rede pela Steam
  (`ISteamNetworkingMessages`), lobby só para amigos, reprodução do input de cada jogador na
  cópia dele, save co-op separado (`win64_coop`, o save normal não é tocado).
- **Scripts Lua** (`src/lua`, REFramework): cópias dos outros jogadores com a aparência,
  vocação e armas deles, sincronia do mundo e dos personagens, pawns em espera durante a sessão.

## Requisitos

- Dragon's Dogma 2 (Steam)
- [REFramework](https://github.com/praydog/REFramework-nightly) (nightly)

## Estado atual

- Ainda não funciona a sincronização de quest
- Fases Inicial de testes de sincronização e animações
- Fase Inicial de sincronização de inimigos e NPCs

## Compilar

MinGW-w64 (GCC) + CMake + Ninja:

```
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build
```

Saída: `build/dd2coop_net.dll` → `reframework/plugins/`; `src/lua/*.lua` → `reframework/autorun/`.

## Licença

GPL-3.0. `third_party/reframework/API.h` é do REFramework (MIT, ver
`third_party/reframework/LICENSE`).
