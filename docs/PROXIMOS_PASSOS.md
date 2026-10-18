# Próximos passos (depois da v0.6.2)

Estado em 2026-10-17. A cópia do jogador remoto (um segundo Arisen) já nasce e vive sem crashar: pawns descarregados antes, calculador de status do jogador preservado, estacionamento quando o jogador remoto está longe. Faltam dois problemas visíveis.

## 1. Correção de posição da cópia: teleporta o tempo todo

**Sintoma (teste com amigo).** O modo novo de correção deixa a cópia mais perto da posição real que o antigo, mas ela dá um "teleporte" visível a cada segundo, mais ou menos.

**Como funciona hoje** (`src/net_sync.cpp`, `correct_clone`):

- O input do jogador remoto é aplicado na cópia (`app.UserInput` dela), e a física/animação da cópia anda sozinha. Por diferenças de física, a posição da cópia se afasta da posição real enviada no pacote: é a deriva (`drift`).
- A cada quadro, a função compara a cópia com a pose do pacote cujo input ela está executando:
  - deriva < `snap` (1,5 m): nada;
  - entre `snap` e `snap_far` (6 m): "puxão" com `app.Character.warp` até `cur - delta * nudge` (25% da deriva), no máximo a cada `nudge_every` (4) quadros;
  - deriva ≥ `snap_far`: warp inteiro até a pose, no máximo 3 por segundo.
- Os parâmetros saem do JSON de configuração do plugin (`snap`, `snap_far`, `nudge`, `nudge_every`). Hoje o Lua não os escreve, então valem os padrões acima. O status por slot traz `snaps` (warps inteiros), `nudges` (puxões) e `drift`.
- Inimigos no cliente (`src/lua/dd2coop_enemies.lua`, `follow`): puxão de 30% acima de 2,5 m; warp inteiro acima de 12 m, no máximo 1/s por inimigo.

**Por que fica ruim.** Cada `Character.warp`, mesmo curto, é um teleporte: reinicia o deslocamento e a locomoção daquele quadro. Puxões de 25% a cada 4 quadros viram uma sequência de pequenos saltos, e a deriva volta a crescer logo em seguida, porque a física continua divergindo.

**Ideias, da mais promissora para a menos:**

1. **Corrigir a velocidade, não a posição.** Em vez de warp, somar um pequeno termo de correção ao vetor de movimento da locomoção (o `vec3` de `app.LocomotionController.update(bool, vec3)`; ver a memória do projeto, "Locomoção") ou ajustar o eixo analógico (`_AxisL`/`AnalogL` do `UserInput`) na direção do alvo. A cópia "corre um pouco mais" até alcançar, sem salto. Warp só acima de ~6 m ou parada.
2. **Corrigir só parado ou devagar.** Quando o jogador remoto está parado (sem input de movimento), deslizar a cópia até a pose com vários warps muito pequenos (2–3 cm por quadro, abaixo do perceptível). Em movimento, tolerar deriva maior (2–3 m).
3. **Aumentar os limites.** `snap` 3 m e `snap_far` 8 m, com `nudge` 5% a cada quadro (pequeno e contínuo em vez de grande e espaçado). É o teste mais barato: não exige código novo, só os valores no JSON do plugin.
4. **Medir antes.** Registrar `drift`, `nudges` e `snaps` por segundo durante um teste real e ver se a deriva cresce em linha reta (física divergente) ou aos saltos (perda de pacotes / jitter). A cópia aplica o input com `jitter` de 6 quadros; perda de pacote faz `held`/`timeouts` subir.

Os inimigos no cliente provavelmente sofrem do mesmo: aplicar a mesma solução depois.

## 2. Zoom da câmera ("flicadas") com a cópia no mundo

**Sintoma.** Com a cópia ativa, a câmera dá zooms rápidos várias vezes no mapa e ao usar skills ou interagir.

**Já verificado:**

- `CharacterManager.ManualPlayer`, `ManualPlayerHuman` e `ManualPlayerPlayer` voltam para o jogador depois da criação (`dd2coop_isolation.lua`, `fix_refs`).
- Nenhum singleton `app.*Manager` aponta direto para a cópia (varredura de 119 singletons).
- A câmera principal às vezes aparece como `BgCamera`. O nome sozinho não diz o papel dela.
- O som também fica posicionado na cópia. O `soundlib.SoundListener` está na MainCamera, com `OffsetGameObj` = `Listener_Position` (filho da MainCamera) e `IsCalcDistanceDecayAtPlayerPos=true`. A posição "do jogador" usada na atenuação ainda não foi localizada.

**Hipóteses** (das revisões externas e do que vimos):

1. As animações e skills do Arisen têm trilhas de câmera (FOV, shake, câmera de ação) que pedem efeitos na câmera principal sem checar se quem executa é o jogador local. Como a cópia executa o input do outro jogador, ela dispara zooms na câmera de quem está jogando. Teste: com a cópia parada e sem rede, o zoom acontece? Se não, a origem é a cópia executando ações.
2. Algum controlador da câmera (alvo secundário, subtarget, lock-on, `MainCameraController.registerTargetObject`) ficou com a cópia registrada ao nascer. O puppet já devolve o alvo principal; procurar listas de alvos.

**Como investigar:** enganchar os métodos de pedido de câmera (FOV, shake, câmera de ação) do `app.MainCameraController`/`app.CameraManager`, registrar quem pede (o `Character` dono da ação) e pular quando o dono for uma cópia. A posição do som provavelmente sai do mesmo registro.

## Regras aprendidas (não quebrar)

- **Nunca** usar `set_field` para gravar um objeto gerenciado em campo de outro objeto. A referência não é contada, e o jogo depois solta o objeto uma vez a mais e crasha (`DD2.exe+0x524feb4`, `+0x52345ae`, rotina de soltar referência em `+0x524fe70`). Usar métodos do jogo (ex.: `PlayerStatusCalculator.setContexts(me:get_Context())`).
- **Não** enganchar métodos `*destroy*` de `via.GameObject`/`GenerateManager`: a criação da cópia crashou.
- **Não** dar reset de scripts com cópia viva. O container de geração está com `add_ref_permanent`, mas outras referências do Lua são soltas.
- **Não** trazer pawns de volta ao vivo (`comebackPartyPawn` crasha em `autoDestroyCharaInstance`). Só voltam logo depois de uma carga de save.
- Pawns: descarregar com `standbyPartyPawn(true, false, true, 0)` (some em ~4 s). `(true, true, false, 0)` os traz de volta.
- A cópia não pode ser destruída nem ter o `CharacterID` trocado.

## Ferramentas de depuração

- `dev/dd2dev_inspect.lua` (instalar à mão no autorun): executa Lua sob demanda (`reframework/data/dd2coop_req.json` → `dd2coop_dump.txt`).
- `dev/dd2dev_trace.lua`: posição e estado da cópia a cada 2 s em `reframework/data/dd2dev_trace.txt`.
- Endereço do crash → método: `reframework/data/dd2coop_method_rva.txt` (RVA + nome), escolhendo o maior RVA ≤ offset. Os nomes só valem quando o offset dentro do método é pequeno.
- Instrução do crash: `objdump -d -M intel --start-address=$((0x140000000+RVA-0x20)) --stop-address=$((0x140000000+RVA+8)) DD2.exe` (objdump do MSYS2; o `.text` é legível no arquivo). Os registradores vêm do `re2_framework_log.txt`.
