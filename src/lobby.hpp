// DD2 Co-op: sessão por lobby da Steam. Ver lobby.cpp.
#pragma once

#include <string>

#include "reframework/API.h"

namespace lobby {

// lê pedidos do Lua (hospedar/entrar/sair) e publica o estado da sessão a cada ~0,5 s
void init(const REFrameworkPluginInitializeParam* param, const std::string& data_dir);

}  // namespace lobby
