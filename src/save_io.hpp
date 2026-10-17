// DD2 Co-op: reconhecimento do I/O de save. Ver save_io.cpp.
#pragma once

#include <string>

#include "reframework/API.h"

namespace save_io {

// observa (sem alterar) as funções de arquivo do DD2.exe nos caminhos da pasta de saves
void init(const REFrameworkPluginInitializeParam* param, const std::string& data_dir);

// a cada frame até conseguir: observa a vtable do ISteamRemoteStorage (onde o DD2 grava o save)
void poll();

// true quando o jogo está lendo e gravando só o save co-op (win64_coop)
bool coop_active();

}  // namespace save_io
