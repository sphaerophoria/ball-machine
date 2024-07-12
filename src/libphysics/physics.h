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

struct pos2 pos2_add(const struct pos2* p, const struct vec2* v);
struct vec2 pos2_sub(const struct pos2* a, const struct pos2* b);

float vec2_length_2(const struct vec2* v);
float vec2_length(const struct vec2* v);
struct vec2 vec2_add(const struct vec2* a, const struct vec2* b);
struct vec2 vec2_sub(const struct vec2* a, const struct vec2* b);
struct vec2 vec2_mul(const struct vec2* vec, float multiplier);
float vec2_dot(const struct vec2* a, const struct vec2* b);
struct vec2 vec2_normalized(const struct vec2* v);

//// Returns the resolution in out if returned true, otherwise there is no
//// resolution to be performed
bool surface_collision_resolution(const struct surface* surface, const struct pos2* p, const struct vec2* v, struct vec2* out);
struct vec2 surface_normal(const struct surface* surface);
void surface_push_if_colliding(const struct surface* surface, struct ball* ball, const struct vec2* obj_velocity, float delta, float max_push);
void apply_ball_collision(struct ball* ball, const struct vec2* resolution, const struct vec2* obj_normal, const struct vec2* obj_velocity, float delta, float elasticity);
void apply_ball_ball_collision(struct ball* a, struct ball* b);
void apply_gravity(struct ball* ball, float delta);
