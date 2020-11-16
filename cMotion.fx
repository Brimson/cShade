
/*
	This work is licensed under a Creative Commons Attribution 3.0 Unported License.
	https://creativecommons.org/licenses/by/3.0/us/

	pFlowBlur() from Jose Negrete AKA BlueSkyDefender [https://github.com/BlueSkyDefender/AstrayFX]
*/

#include "ReShade.fxh"

uniform float _Lambda <
	ui_type = "drag";
	ui_label = "Lambda";
	ui_category = "Optical Flow";
> = 0.01;

uniform int _Samples <
	ui_type = "drag";
	ui_min = 0; ui_max = 16;
	ui_label = "Blur Amount";
	ui_category = "Blur Composite";
> = 4;

uniform int Debug <
	ui_type = "combo";
	ui_items = "Off\0Depth\0Direction\0";
	ui_label = "Debug View";
	ui_category = "Blur Composite";
> = 0;

static const int size = 1024;

texture2D t_LOD    { Width = size; Height = size; Format = R16F; MipLevels = 5.0; };
texture2D t_cFrame { Width = size; Height = size; Format = R16F; };
texture2D t_pFrame { Width = size; Height = size; Format = R16F; };

sampler2D s_Linear { Texture = ReShade::BackBufferTex; SRGBTexture = true; };
sampler2D s_LOD    { Texture = t_LOD; MipLODBias = 4.0; };
sampler2D s_cFrame { Texture = t_cFrame; };
sampler2D s_pFrame { Texture = t_pFrame; };

struct vs_in
{
	float4 vpos : SV_POSITION;
	float2 uv : TEXCOORD0;
};

/* [ Pixel Shaders ] */

// Empty shader to generate brightpass, mipmaps, and previous frame
void pLOD(vs_in input, out float c : SV_Target0, out float p : SV_Target1)
{
	float3 col = tex2Dlod(s_Linear, float4(input.uv, 0.0, 0.0)).rgb;
	float lum = max(length(col), 0.00001f); // Brightness filter
	c = log2(1.0 / lum);
	p = tex2Dlod(s_cFrame, float4(input.uv, 0.0, 0.0)).x; // Output the c_Frame we got from last frame
}

/*
	- Color optical flow, by itself, is too small to make motion blur
	- BSD's eMotion does not have this issue because depth texture colors are flat
	- Gaussian blur is expensive and we do not want more passes

	Question: What is the fastest way to smoothly blur a picture?
	Answer: Cubic-filtered texture LOD

	Taken from [https://github.com/haasn/libplacebo/blob/master/src/shaders/sampling.c] [GPL 2.1]
	How bicubic scaling with 4 texel fetches is done [http://www.mate.tue.nl/mate/pdfs/10318.pdf]
	'Efficient GPU-Based Texture Interpolation using Uniform B-Splines'
*/

float4 calcweights(float s)
{
	float4 t = float4(-0.5, 0.1666, 0.3333, -0.3333) * s + float4(1.0, 0.0, -0.5, 0.5);
	t = t * s + float4(0.0, 0.0, -0.5, 0.5);
	t = t * s + float4(-0.6666, 0.0, 0.8333, 0.1666);
	float2 a = 1.0 / t.zw;
	t.xy = t.xy * a + 1.0;
	t.x = t.x + s;
	t.y = t.y - s;
	return t;
}

// NOTE: This is a grey cubic filter. Cubic.fx is the RGB version of this ;)
void pCFrame(vs_in input, out float c : SV_Target0)
{
	const float2 texsize = tex2Dsize(s_LOD, 4.0);
	const float2 pt = 1.0 / texsize;
	float2 fcoord = frac(input.uv * texsize + 0.5);
	float4 parmx = calcweights(fcoord.x);
	float4 parmy = calcweights(fcoord.y);
	float4 cdelta;
	cdelta.xz = parmx.rg * float2(-pt.x, pt.x);
	cdelta.yw = parmy.rg * float2(-pt.y, pt.y);
	// first y-interpolation
	float3 a;
	a.r = tex2Dlod(s_LOD, float4(input.uv + cdelta.xy, 0.0, 0.0)).x;
	a.g = tex2Dlod(s_LOD, float4(input.uv + cdelta.xw, 0.0, 0.0)).x;
	a.b = lerp(a.g, a.r, parmy.b);
	// second y-interpolation
	float3 b;
	b.r = tex2Dlod(s_LOD, float4(input.uv + cdelta.zy, 0.0, 0.0)).x;
	b.g = tex2Dlod(s_LOD, float4(input.uv + cdelta.zw, 0.0, 0.0)).x;
	b.b = lerp(b.g, b.r, parmy.b);
	// x-interpolation
	c = lerp(b.b, a.b, parmx.b).x;
}

/*
	Algorithm from [https://github.com/mattatz/unity-optical-flow] [MIT License]
	Optimization from [https://www.shadertoy.com/view/3l2Gz1] [CC BY-NC-SA 3.0]
	
	ISSUE:
	mFlow combines the optical flow result of the current AND previous frame.
	This means there are blurred ghosting that happens frame-by-frame
*/

float2 mFlow(float prev, float curr)
{
	float2 d; // Sobel operator gradient
	d.x = ddx(curr + prev);
	d.y = ddy(curr + prev);

	float dt = curr - prev; // dt (difference)
	float gmag = sqrt(d.x * d.x + d.y * d.y + _Lambda);
	float2 flow = dt * d / gmag;

	return flow;
}

void pFlowBlur(vs_in input, out float3 c : SV_Target0)
{
	// Calculate optical flow and blur direction
	// BSD did this in another pass, but this should be cheaper
	// Putting it here also means the values are not clamped!
	float prev = tex2Dlod(s_pFrame, float4(input.uv, 0.0, 0.0)).x; // cubic from last frame
	float curr = tex2Dlod(s_cFrame, float4(input.uv, 0.0, 0.0)).x; // cubic from this frame
	float2 oFlow = mFlow(prev, curr);

	// Interleaved Gradient Noise by Jorge Jimenez to smoothen blur samples
	// [http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare]
	const float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
	float ign = frac(magic.z * frac(dot(input.vpos.xy, magic.xy)));

	// Apply motion blur
	const float pt = 1.0 / size;
	float total, weight = 1.0;

	[loop]
	for (float i = -_Samples; i <= _Samples; i ++)
	{
		float3 csample;
		const float offset = (i + ign);
		csample += tex2Dlod(s_Linear, float4(input.uv + (pt * oFlow * offset), 0.0, 0.0)).rgb;
		c += csample;
		total += weight;
	}

	if (Debug == 0)
		c /= total;
	else if (Debug == 1)
		c = curr;
	else
		c = float3(mad(oFlow, 0.5, 0.5), 0.0);
}

technique cMotionBlur < ui_tooltip = "Color-Based Motion Blur"; >
{
	pass LOD
	{
		VertexShader = PostProcessVS;
		PixelShader = pLOD;
		RenderTarget0 = t_LOD;
		RenderTarget1 = t_pFrame; // Store previous frame's cubic for optical flow
		ClearRenderTargets = true; // Trying to fix things, might be redundant
	}

	pass CubicFrame
	{
		VertexShader = PostProcessVS;
		PixelShader = pCFrame;
		RenderTarget0 = t_cFrame;
	}

	pass FlowBlur
	{
		VertexShader = PostProcessVS;
		PixelShader = pFlowBlur;
		SRGBWriteEnable = true;
	}
}
