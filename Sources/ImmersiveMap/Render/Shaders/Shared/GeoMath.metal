// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "GeoMath.h"

float4x4 rotationMatrix(float3 axis, float angle) {
    // Normalize the axis to ensure it's a unit vector
    axis = normalize(axis);
    
    float cosA = cos(angle);
    float sinA = sin(angle);
    float oneMinusCos = 1.0 - cosA;
    
    float x = axis.x;
    float y = axis.y;
    float z = axis.z;
    
    // Construct the rotation matrix
    float4x4 matrix;
    
    matrix[0][0] = cosA + x * x * oneMinusCos;
    matrix[0][1] = x * y * oneMinusCos - z * sinA;
    matrix[0][2] = x * z * oneMinusCos + y * sinA;
    matrix[0][3] = 0.0;
    
    matrix[1][0] = x * y * oneMinusCos + z * sinA;
    matrix[1][1] = cosA + y * y * oneMinusCos;
    matrix[1][2] = y * z * oneMinusCos - x * sinA;
    matrix[1][3] = 0.0;
    
    matrix[2][0] = x * z * oneMinusCos - y * sinA;
    matrix[2][1] = y * z * oneMinusCos + x * sinA;
    matrix[2][2] = cosA + z * z * oneMinusCos;
    matrix[2][3] = 0.0;
    
    matrix[3][0] = 0.0;
    matrix[3][1] = 0.0;
    matrix[3][2] = 0.0;
    matrix[3][3] = 1.0;
    
    return matrix;
}

float wrap(float x, float size) {
    return x - size * floor((x + size * 0.5) / size);
}

float getYMercNorm(float latitude) {
    float sin_pan = sin(latitude);
    float max_sin_pan = tanh(M_PI_F); // == sin(maxLatitude)
    float clamped_sin_pan = max(-max_sin_pan, min(max_sin_pan, sin_pan));
    float y_pan_merc = 0.5 * log((1.0 + clamped_sin_pan) / (1.0 - clamped_sin_pan));
    float panY_merc_norm = y_pan_merc / M_PI_F; // normalized to [-1, 1]
    return panY_merc_norm;
}

float4x4 translationMatrix(float3 t) {
    return float4x4(
        float4(1, 0, 0, t.x),
        float4(0, 1, 0, t.y),
        float4(0, 0, 1, t.z),
        float4(0, 0, 0, 1)
    );
}
