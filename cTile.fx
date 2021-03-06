
uniform float kScale <
    ui_label = "Scale";
    ui_type = "drag";
    ui_step = 0.1;
> = 100.0;

uniform float2 kCenter <
    ui_label = "Center";
    ui_type = "drag";
    ui_step = 0.001;
> = float2(0.0, 0.0);

texture2D r_source : COLOR;

sampler2D s_source
{
    Texture = r_source;
    AddressU = MIRROR;
    AddressV = MIRROR;
    #if BUFFER_COLOR_BIT_DEPTH != 10
        SRGBTexture = true;
    #endif
};

struct v2f { float4 vpos : SV_POSITION; float2 uv : TEXCOORD0; };

v2f v_tile(in uint id : SV_VertexID)
{
    const float2 size = float2(BUFFER_WIDTH, BUFFER_HEIGHT);

    v2f o;
    float2 texcoord;
    texcoord.x = (id == 2) ? 2.0 : 0.0;
    texcoord.y = (id == 1) ? 2.0 : 0.0;
    o.vpos = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);

    o.uv -= 0.5;
    o.uv += texcoord + float2(kCenter.x, -kCenter.y);
    float2 s = o.uv * size * (kScale * 0.01);
    o.uv = floor(s) / size;
    o.uv += 0.5;
    return o;
}

void p_tile(v2f input, out float3 c : SV_Target0)
{
    c = tex2D(s_source, input.uv).rgb;
}

technique Tile
{
    pass
    {
        VertexShader = v_tile;
        PixelShader = p_tile;
        #if BUFFER_COLOR_BIT_DEPTH != 10
            SRGBWriteEnable = true;
        #endif
    }
}
