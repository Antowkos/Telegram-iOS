//
//  Shader.metal
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 23.10.2024.
//

#include <metal_stdlib>
using namespace metal;

typedef struct {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
} ImageVertex;

typedef struct {
    float4 position [[position]];
    float2 texcoord;
} ImageColorInOut;

vertex ImageColorInOut mapTexture(ImageVertex in [[stage_in]]) {
    ImageColorInOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

float4 ycbcrToRgba(float4 ycbcr) {
    const float4x4 ycbcrToRGBTransform = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
    );

    return ycbcrToRGBTransform * ycbcr;
}

constexpr sampler colorSampler(mip_filter::linear,
                               mag_filter::linear,
                               min_filter::linear);

fragment float4 displayTexture(ImageColorInOut in [[stage_in]],
                               texture2d<float, access::sample> capturedImageTextureY [[ texture(0) ]],
                               texture2d<float, access::sample> capturedImageTextureCbCr [[ texture(1) ]]) {

    float4 ycbcr = float4(capturedImageTextureY.sample(colorSampler, in.texcoord).r,
                          capturedImageTextureCbCr.sample(colorSampler, in.texcoord).rg, 1.0);

    return ycbcrToRgba(ycbcr);
}
