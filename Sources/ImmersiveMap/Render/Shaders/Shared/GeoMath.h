// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  GeoMath.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;

#ifndef GEO_MATH
#define GEO_MATH

float wrap(float x, float size);
float4x4 rotationMatrix(float3 axis, float angle);
float4x4 translationMatrix(float3 t);
float getYMercNorm(float latitude);

#endif
