// DD2 Co-op: sincronização do jogador 2 pela rede. Ver net_sync.cpp.
#pragma once

#include "reframework/API.h"

namespace net_sync {

// registra o hook em app.UserInput.update e o callback por frame
void init(const REFrameworkPluginInitializeParam* param);

}  // namespace net_sync
