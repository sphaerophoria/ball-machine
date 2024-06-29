#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <physics.h>

extern unsigned char __data_end;
extern unsigned char __heap_base;

extern void logWasm(const char* offs, int len);

size_t numDigits(int x) {
    int count = 1;
    while (true) {
        x /= 10;
        if (x == 0) {
            return count;
        }
        count += 1;
    }

}

void printNum(int x) {
    int num_digits = numDigits(x);

    if (num_digits > 20) {
        __builtin_unreachable();
    }

    char out_buf[21] = {0};

    for (int i = 0; i < num_digits; ++i) {
        out_buf[num_digits - i - 1] = '0' + x % 10;
        x /= 10;
    }

    logWasm(out_buf, num_digits);
}

#define PAGE_SIZE 65536

static struct ball* BALLS_MEMORY = NULL;
static int32_t* CANVAS_MEMORY = NULL;

static char* alloc_ptr;
static int last_alloc_size = 0;

static size_t heapSize(void) {
    return __builtin_wasm_memory_size(0) * PAGE_SIZE;

}

void init(size_t max_num_balls, size_t max_canvas_size) {
    const size_t balls_required_size = max_num_balls * sizeof(struct ball);
    // FIXME: Alignment
    const size_t required_memory = balls_required_size + max_canvas_size * sizeof(int32_t) + (int)&__heap_base;
    if (required_memory >= heapSize()) {
        const size_t required_pages = (required_memory + PAGE_SIZE - 1) / PAGE_SIZE;
        __builtin_wasm_memory_grow(0, required_pages);
    }

    // FIXME: Alignment
    BALLS_MEMORY = (struct ball*)&__heap_base;
    // FIXME: Alignment
    CANVAS_MEMORY = (int32_t*)((char*)BALLS_MEMORY + balls_required_size);
}

void deinit(void) {

}

void* ballsMemory(void) {
    return BALLS_MEMORY;
}

void* canvasMemory(void) {
    return CANVAS_MEMORY;
}

void* saveMemory(void) {
    return NULL;
}

size_t saveSize(void) {
    return 0;
}

#define PLATFORM_Y 0.2
void save(void) {}
void load(void) {}

void step(size_t num_balls, float delta) {
    struct surface surface = {
        .a = {
            .x = 0,
            .y = PLATFORM_Y,
        },
        .b = {
            .x = 1,
            .y = PLATFORM_Y,
        }
    };

    for (size_t i = 0; i < num_balls; ++i) {
        struct vec2 ball_offs = vec2_mul(surface_normal(surface), -BALLS_MEMORY[i].r);
        struct vec2 resolution;
        struct pos2 collision_point = pos2_add(BALLS_MEMORY[i].pos, ball_offs);
        if (surface_collision_resolution(surface, collision_point, vec2_mul(BALLS_MEMORY[i].velocity, delta), &resolution)) {
            apply_ball_collision(&BALLS_MEMORY[i], resolution, surface_normal(surface), delta);
        }
    }

}

void render(size_t canvas_width, size_t canvas_height) {
    for (size_t i = 0; i< canvas_width * canvas_height; ++i) {
        CANVAS_MEMORY[i] = 0xff00ffff;
    }

    for (size_t i = 0; i< canvas_width; ++i) {
        size_t y = canvas_height - PLATFORM_Y * canvas_width;
        CANVAS_MEMORY[y * canvas_width + i] = 0xff000000;
    }
}
