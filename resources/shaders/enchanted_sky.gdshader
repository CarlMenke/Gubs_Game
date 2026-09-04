shader_type sky;
render_mode use_quarter_res_pass;

// Night sky for Whisperbloom Hollow. Everything is procedural — no cubemap, no
// star texture — so the whole sky costs one resource and stays crisp at any
// resolution.
//
// The expensive, soft, low-frequency half of the sky (aurora ribbons and cloud
// wisps) is rendered in the quarter-res pass and composited back over the
// full-res pass. That is a 16x saving on the only part of this shader with a
// noise fbm in it, and quarter-res blur is free art direction on something that
// is meant to look like vapour anyway. Stars are the opposite — they must be
// full-res or they crawl — so they live in the main pass and are skipped
// entirely for the radiance cubemap, where sub-pixel points contribute nothing
// but noise to the ambient term.

// Colour uniforms are declared in LINEAR space so the in-shader defaults match
// the sRGB values `arena_sky.tres` writes back through the `source_color` hint.
group_uniforms gradient;
uniform vec3 zenith_color : source_color = vec3(0.0100, 0.0085, 0.0397);
uniform vec3 horizon_color : source_color = vec3(0.0116, 0.0550, 0.0432);
uniform vec3 void_color : source_color = vec3(0.0023, 0.0027, 0.0049);
uniform float horizon_falloff : hint_range(0.2, 3.0) = 0.62;
uniform float void_falloff : hint_range(0.05, 1.0) = 0.42;
uniform float sky_energy : hint_range(0.0, 4.0) = 1.0;

group_uniforms forest_glow;
uniform vec3 forest_glow_color : source_color = vec3(0.2633, 0.1329, 0.0331);
uniform float forest_glow_energy : hint_range(0.0, 2.0) = 0.70;
uniform float forest_glow_band : hint_range(0.02, 0.6) = 0.13;

group_uniforms stars;
uniform vec3 star_color : source_color = vec3(0.6921, 0.7874, 1.0);
uniform float star_energy : hint_range(0.0, 8.0) = 2.2;
uniform float star_density : hint_range(20.0, 260.0) = 96.0;
uniform float star_coverage : hint_range(0.0, 1.0) = 0.11;
uniform float star_twinkle : hint_range(0.0, 1.0) = 0.45;
uniform float star_twinkle_speed : hint_range(0.0, 6.0) = 1.3;
uniform vec3 star_band_axis = vec3(0.36, 0.62, -0.7);
uniform float star_band_width : hint_range(0.05, 1.0) = 0.34;
uniform vec3 star_haze_color : source_color = vec3(0.0397, 0.0550, 0.1706);
uniform float star_haze_energy : hint_range(0.0, 2.0) = 0.30;

group_uniforms moon;
// Used only when `moon_follow_light` is off or no DirectionalLight3D exists.
uniform vec3 moon_direction = vec3(-0.42, 0.38, -0.82);
uniform bool moon_follow_light = true;
uniform vec3 moon_color : source_color = vec3(0.6921, 0.7874, 1.0);
uniform float moon_energy : hint_range(0.0, 20.0) = 5.5;
uniform float moon_angular_size : hint_range(0.005, 0.2) = 0.038;
uniform float moon_phase : hint_range(-1.0, 1.0) = 0.52;
uniform float moon_mare : hint_range(0.0, 1.0) = 0.35;
uniform vec3 moon_halo_color : source_color = vec3(0.1005, 0.1706, 0.4770);
uniform float moon_halo_energy : hint_range(0.0, 3.0) = 0.45;
uniform float moon_halo_falloff : hint_range(4.0, 400.0) = 70.0;

group_uniforms aurora;
uniform vec3 aurora_low_color : source_color = vec3(0.0220, 0.3424, 0.1706);
uniform vec3 aurora_high_color : source_color = vec3(0.0946, 0.0550, 0.3424);
uniform float aurora_energy : hint_range(0.0, 3.0) = 0.22;
uniform float aurora_height : hint_range(-0.2, 0.9) = 0.22;
uniform float aurora_width : hint_range(0.02, 0.6) = 0.085;
uniform float aurora_speed : hint_range(0.0, 0.5) = 0.035;
uniform float aurora_azimuth : hint_range(-3.15, 3.15) = -1.15;
uniform float aurora_spread : hint_range(0.2, 8.0) = 3.2;
uniform float aurora_curtain : hint_range(0.0, 1.0) = 0.55;

group_uniforms clouds;
uniform vec3 cloud_color : source_color = vec3(0.0100, 0.0116, 0.0245);
uniform vec3 cloud_lit_color : source_color = vec3(0.2330, 0.2738, 0.4770);
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.75;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.42;
uniform float cloud_scale : hint_range(0.2, 8.0) = 1.15;
uniform float cloud_speed : hint_range(0.0, 0.2) = 0.012;
uniform float cloud_horizon_fade : hint_range(0.0, 0.6) = 0.06;
// Clouds sit on a finite dome, so walking the island should slide them a hair.
uniform float cloud_parallax : hint_range(0.0, 0.01) = 0.0012;


float hash12(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

vec3 hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < octaves; i++) {
		sum += amp * value_noise(p);
		p = p * 2.03 + vec2(17.1, 9.7);
		amp *= 0.5;
	}
	return sum;
}

// One octave of star cells. Each cell holds at most one star, placed away from
// its own borders so the single-cell lookup never clips a star in half.
float star_layer(vec3 dir, float density, float coverage, float time, float phase) {
	vec3 p = dir * density;
	vec3 cell = floor(p);
	vec3 f = p - cell;
	vec3 r = hash33(cell + phase);
	float present = step(1.0 - coverage, r.z);
	vec3 star_pos = 0.3 + 0.4 * vec3(r.x, r.y, fract(r.x + r.y));
	float d = length(f - star_pos);
	float core = smoothstep(0.34, 0.0, d);
	float mag = 0.25 + 0.75 * hash13(cell + phase + 5.13);
	float twinkle = 1.0 - star_twinkle * (0.5 + 0.5 * sin(time * star_twinkle_speed + r.x * 43.0));
	return present * pow(core, 4.0) * mag * twinkle;
}

vec3 moon_dir() {
	vec3 d = moon_direction;
	if (moon_follow_light && LIGHT0_ENABLED) {
		d = LIGHT0_DIRECTION;
	}
	return normalize(d);
}

// Aurora + clouds, premultiplied: .rgb is what to add, .a is how much of the
// sky behind to cover. Composites as `sky * (1 - a) + rgb`.
vec4 vapour(vec3 dir, vec3 cam_pos, float time, int cloud_octaves) {
	float az = atan(dir.z, dir.x);
	vec3 md = moon_dir();
	float moon_cos = max(dot(dir, md), 0.0);

	// --- aurora: three offset ribbons, each a gaussian band whose centre
	// height wanders with slow noise. No raymarch; it is a painted curtain.
	float aurora_mask = pow(max(cos(az - aurora_azimuth), 0.0), aurora_spread);
	aurora_mask *= smoothstep(-0.05, 0.15, dir.y);
	float aurora_sum = 0.0;
	float aurora_grad = 0.0;
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		float seed = fi * 7.3;
		float wander = fbm(vec2(az * 1.1 + time * aurora_speed, seed), 2) - 0.5;
		float centre = aurora_height + 0.10 * wander + 0.045 * (fi - 1.0);
		float width = aurora_width * (0.65 + 0.45 * hash12(vec2(seed, 3.1)));
		float t = (dir.y - centre) / width;
		float band = exp(-t * t);
		// Vertical striations are what sells a curtain over a smear.
		float streak = mix(1.0, value_noise(vec2(az * 22.0 + seed, time * 0.05)), aurora_curtain);
		aurora_sum += band * streak * (0.6 + 0.4 * hash12(vec2(seed, 8.4)));
		aurora_grad += band * clamp(t * 0.5 + 0.5, 0.0, 1.0);
	}
	aurora_grad = aurora_sum > 0.0001 ? aurora_grad / aurora_sum : 0.5;
	vec3 aurora = mix(aurora_low_color, aurora_high_color, aurora_grad);
	aurora *= aurora_sum * aurora_mask * aurora_energy;

	// --- clouds: flat-dome projection so wisps converge toward the horizon
	// the way a real overcast layer does.
	float dome = max(dir.y + 0.14, 0.06);
	vec2 uv = dir.xz / dome * cloud_scale;
	uv += cam_pos.xz * cloud_parallax;
	uv += vec2(time * cloud_speed, time * cloud_speed * 0.42);
	float n = fbm(uv, cloud_octaves);
	float cover = smoothstep(cloud_coverage, cloud_coverage + 0.26, n);
	cover *= smoothstep(cloud_horizon_fade * 0.2, cloud_horizon_fade + 0.16, dir.y);
	cover *= cloud_opacity;

	vec3 lit = mix(cloud_color, cloud_lit_color, pow(moon_cos, 6.0));
	lit = mix(lit, lit + forest_glow_color * 0.35, smoothstep(0.45, 0.05, dir.y));

	// Premultiply: the cloud covers the aurora it drifts in front of.
	return vec4(lit * cover + aurora * (1.0 - cover), cover);
}


void sky() {
	vec3 dir = normalize(EYEDIR);
	float az = atan(dir.z, dir.x);

	// Godot forbids an early `return` from sky(), so the two passes are an
	// if/else rather than a guard clause.
	if (AT_QUARTER_RES_PASS) {
		// 2 octaves is all that survives a quarter-res buffer anyway.
		vec4 v = vapour(dir, POSITION, TIME, 2);
		COLOR = v.rgb;
		ALPHA = v.a;
	} else {
		// --- graded backdrop -----------------------------------------------
		float up = clamp(dir.y, 0.0, 1.0);
		vec3 col = mix(horizon_color, zenith_color, pow(up, horizon_falloff));

		// Distant forest glow: a warm band hugging the horizon, broken up in
		// azimuth so it reads as light from somewhere rather than a vignette.
		float band = 1.0 - clamp(abs(dir.y) / forest_glow_band, 0.0, 1.0);
		float patchy = 0.45 + 0.55 * fbm(vec2(az * 0.9, 3.7), 2);
		col += forest_glow_color * pow(band, 2.4) * forest_glow_energy * patchy;

		// Below the horizon the island is floating over nothing much.
		col = mix(col, void_color, 1.0 - smoothstep(-void_falloff, 0.0, dir.y));

		// --- stars ---------------------------------------------------------
		// Skipped for the radiance cubemap: at 256px a star is sub-texel and only
		// adds sparkle noise to the ambient light.
		if (!AT_CUBEMAP_PASS) {
			float band_t = dot(dir, normalize(star_band_axis)) / star_band_width;
			float galactic = exp(-band_t * band_t);
			float haze_n = fbm(vec2(az * 2.2, dir.y * 3.4), 2);
			col += star_haze_color * galactic * star_haze_energy * (0.35 + 0.65 * haze_n);

			float atmo = smoothstep(-0.02, 0.22, dir.y);
			float s = star_layer(dir, star_density, star_coverage * (1.0 + galactic), TIME, 0.0);
			s += star_layer(dir, star_density * 0.43, star_coverage * 0.45, TIME, 19.7) * 1.8;
			col += star_color * s * star_energy * atmo;
		}

		// --- moon ----------------------------------------------------------
		vec3 md = moon_dir();
		float moon_cos = clamp(dot(dir, md), -1.0, 1.0);
		float ang = acos(moon_cos);

		// Halo first, so the disc sits inside its own bloom.
		col += moon_halo_color * pow(max(moon_cos, 0.0), moon_halo_falloff) * moon_halo_energy;
		col += moon_halo_color * pow(max(moon_cos, 0.0), 9.0) * moon_halo_energy * 0.06;

		float disc = 1.0 - smoothstep(moon_angular_size * 0.90, moon_angular_size * 1.05, ang);
		if (disc > 0.0) {
			// Disc-local frame, so the terminator and the mare stay put as the
			// camera turns instead of sliding across the face.
			vec3 ref = abs(md.y) > 0.95 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
			vec3 tx = normalize(cross(ref, md));
			vec3 ty = cross(md, tx);
			vec2 duv = vec2(dot(dir, tx), dot(dir, ty)) / moon_angular_size;
			float r2 = clamp(1.0 - dot(duv, duv), 0.0, 1.0);
			float sphere = sqrt(r2);
			float lit = smoothstep(-0.30, 0.34, duv.x * 0.85 + moon_phase);
			float mare = mix(1.0, 0.55 + 0.45 * fbm(duv * 1.7 + 4.0, 2), moon_mare);
			col += moon_color * moon_energy * disc * lit * mare * (0.55 + 0.45 * sphere);
		}

		// --- aurora + clouds from the quarter-res buffer --------------------
		// The cubemap pass has no sub-res buffer to read, so it recomputes a
		// one-octave version — cheap, and the ambient term only wants the
		// low-frequency colour anyway.
		vec4 v = QUARTER_RES_COLOR;
		if (AT_CUBEMAP_PASS) {
			v = vapour(dir, POSITION, TIME, 1);
		}
		col = col * (1.0 - v.a) + v.rgb;

		COLOR = col * sky_energy;
	}
}
