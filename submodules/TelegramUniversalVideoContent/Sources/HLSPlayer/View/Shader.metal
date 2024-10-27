//
//  Shader.metal
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 23.10.2024.
//

#include <metal_stdlib>
using namespace metal;

//Vertex Function (Shader)
vertex float4 vertexShader(const device float4 *vertices [[buffer(0)]], uint vid [[vertex_id]]){
    return vertices[vid];
}

//Fragment Function (Shader)
fragment float4 fragmentShader(float4 in [[stage_in]]){
    //set color fragment to red
    return float4(1.0, 0.0, 0.0, 1.0);
}
