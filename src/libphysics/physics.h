#include <stdint.h>
#include <stdbool.h>

struct pos2 {
    float x;
    float y;
};

struct vec2 {
    float x;
    float y;
};

// Assumed normal points up if a is left of b, down if b is left of a
struct surface {
    struct pos2 a;
    struct pos2 b;
};

struct ball {
    struct pos2 pos;
    float r;
    struct vec2 velocity;
};

struct pos2 pos2_add(struct pos2 p, struct vec2 v);
struct vec2 pos2_sub(struct pos2 a, struct pos2 b);

float vec2_length_2(struct vec2 v);
float vec2_length(struct vec2 v);
struct vec2 vec2_add(struct vec2 a, struct vec2 b);
struct vec2 vec2_sub(struct vec2 a, struct vec2 b);
struct vec2 vec2_mul(struct vec2 vec, float multiplier);
float vec2_dot(struct vec2 a, struct vec2 b);
struct vec2 vec2_normalized(struct vec2 v);

//// Returns the resolution in out if returned true, otherwise there is no
//// resolution to be performed
bool surface_collision_resolution(struct surface surface, struct pos2 p, struct vec2 v, struct vec2* out);
struct vec2 surface_normal(struct surface surface);
void surface_push_if_colliding(struct surface surface, struct ball* ball, float delta);
void apply_ball_collision(struct ball* ball, struct vec2 resolution, struct vec2 obj_normal, float delta, float elasticity);
void apply_ball_ball_collision(struct ball* a, struct ball* b);