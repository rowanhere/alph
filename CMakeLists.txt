cmake_minimum_required(VERSION 3.18)
project(alph_cuda_miner LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

add_executable(alph-cuda-miner src/alph_cuda_miner.cu)
set_target_properties(alph-cuda-miner PROPERTIES CUDA_SEPARABLE_COMPILATION OFF)

if (WIN32)
  target_link_libraries(alph-cuda-miner PRIVATE ws2_32)
endif()

