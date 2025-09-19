shader_type canvas_item;

uniform sampler2D screen_tex;
uniform vec2 screen_size;
uniform float thickness : hint_range(1.0, 10.0) = 3.0;
uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 0.0, 1.0);
uniform float enabled : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 base = texture(screen_tex, uv).rgb;

	if (enabled > 0.5) {
		float edge = 0.0;
		for (float x = -thickness; x <= thickness; x++) {
			for (float y = -thickness; y <= thickness; y++) {
				vec2 offset = vec2(x, y) / screen_size;
				vec3 neighbor = texture(screen_tex, uv + offset).rgb;
				edge += distance(base, neighbor);
			}
		}

		if (edge > 0.1) {
			COLOR = outline_color;
		} else {
			COLOR = vec4(base, 0.0);
		}
	} else {
		COLOR = vec4(base, 0.0);
	}
}
