cmake_minimum_required(VERSION 3.20)
project(dd2coop CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(dd2coop_net SHARED src/dd2coop_net.cpp src/net_sync.cpp src/save_io.cpp src/lobby.cpp)
target_include_directories(dd2coop_net PRIVATE third_party)
set_target_properties(dd2coop_net PROPERTIES PREFIX "")
# Sem dependência das DLLs do MinGW em tempo de execução: o jogo não as tem.
target_link_options(dd2coop_net PRIVATE -static -static-libgcc -static-libstdc++)

include(CTest)
if(BUILD_TESTING)
    add_executable(input_safety_test tests/input_safety_test.cpp)
    target_include_directories(input_safety_test PRIVATE src)
    target_link_options(input_safety_test PRIVATE -static -static-libgcc -static-libstdc++)
    add_test(NAME input_safety COMMAND input_safety_test)
    add_executable(net_playback_test tests/net_playback_test.cpp src/save_io.cpp)
    target_include_directories(net_playback_test PRIVATE src third_party)
    target_link_options(net_playback_test PRIVATE -static -static-libgcc -static-libstdc++)
    add_test(NAME net_playback COMMAND net_playback_test)
    add_executable(motion_correction_test tests/motion_correction_test.cpp)
    target_link_options(motion_correction_test PRIVATE -static -static-libgcc -static-libstdc++)
    add_test(NAME motion_correction COMMAND motion_correction_test)
endif()

# launcher: baixa/atualiza o mod pela Release do GitHub e abre o jogo
add_executable(DD2Coop_Launcher WIN32 launcher/launcher.cpp)
target_compile_definitions(DD2Coop_Launcher PRIVATE UNICODE _UNICODE)
target_link_libraries(DD2Coop_Launcher PRIVATE winhttp bcrypt shell32 ole32 uuid psapi advapi32)
target_link_options(DD2Coop_Launcher PRIVATE -static -static-libgcc -static-libstdc++ -municode)
