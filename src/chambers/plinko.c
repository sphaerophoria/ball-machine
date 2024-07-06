#include <physics.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Manual memory management, https://github.com/wingo/walloc is a reasonable
// alternative
enum {
  kPageSize = 65536,
};
extern unsigned char __data_end;   // NOLINT
extern unsigned char __heap_base;  // NOLINT

static struct ball* balls_memory = NULL;
static int32_t* canvas_memory = NULL;

static size_t ballsSizeBytes(size_t num_balls) {
  return num_balls * sizeof(struct ball);
}

static size_t canvasSizeBytes(size_t num_pixels) {
  return num_pixels * sizeof(*canvas_memory);
}

static size_t memorySizeBytes(void) {
  return __builtin_wasm_memory_size(0) * kPageSize;
}

#define ROUND_UP(val, step) \
  (typeof(val))((val) + ((step) - (typeof(step))(val) % (step)) % (step))

void init(size_t max_num_balls, size_t max_canvas_size) {
  unsigned char* alloc_ptr = &__heap_base;
  balls_memory = ROUND_UP(alloc_ptr, _Alignof(struct ball));
  alloc_ptr = balls_memory + max_num_balls;

  canvas_memory = ROUND_UP(alloc_ptr, _Alignof(int32_t));
  alloc_ptr = canvas_memory + max_canvas_size;

  if (alloc_ptr >= memorySizeBytes()) {
    size_t const required_pages =
        ROUND_UP((size_t)alloc_ptr, kPageSize) / kPageSize;
    __builtin_wasm_memory_grow(0, required_pages);
  }
}

void* ballsMemory(void) { return balls_memory; }
void* canvasMemory(void) { return canvas_memory; }
void* saveMemory(void) { return NULL; }
size_t saveSize(void) { return 0; }
void save(void) {}
void load(void) {}

#define PEG_RADIUS 0.01
#define MAX_PEGS_PER_ROW 8
#define PEGS_PER_2_ROWS (MAX_PEGS_PER_ROW * 2 - 1)
#define PEG_X_SPACING (1.0 / (MAX_PEGS_PER_ROW - 1))
#define PEG_Y_SPACING (PEG_X_SPACING / 2.0)
#define PEG_Y_MAX 0.7

struct pos2 pegLoc(int i) {
  // This is hard to parse, but at a high level it isn't crazy
  //
  // Each row has either N or N+1 elements
  // We batch by N + N + 1 because that's where the repetition starts
  //
  // In each 2 row batch, we do almost the same thing, but make slight
  // adjustments if we're in an even or odd row
  //
  // We then scale the [0,1] coordinate space into something smaller so that
  // pegs aren't drawn on the very edge of the screen
  int y_2idx = i / (float)PEGS_PER_2_ROWS;
  bool is_short_row = (i % PEGS_PER_2_ROWS) >= MAX_PEGS_PER_ROW;
  int x_idx = (i % PEGS_PER_2_ROWS) % MAX_PEGS_PER_ROW;
  int y_idx = y_2idx * 2;
  if (is_short_row) {
    y_idx += 1;
  }
  float y = y_idx * PEG_Y_SPACING;
  float x = PEG_X_SPACING * x_idx;
  if (is_short_row) {
    x += PEG_X_SPACING / 2.0;
  }

  return (struct pos2){
      .x = x * 0.9 + 0.05,
      .y = y * 0.9 + 0.05,
  };
}

void step(size_t num_balls, float delta) {
  int peg_idx = 0;
  while (true) {
    const struct pos2 peg_pos = pegLoc(peg_idx++);
    if (peg_pos.y > PEG_Y_MAX) {
      break;
    }

    for (size_t ball_idx = 0; ball_idx < num_balls; ++ball_idx) {
      struct ball* ball = &balls_memory[ball_idx];
      const struct vec2 offs = pos2_sub(&ball->pos, &peg_pos);
      float const diff = vec2_length(&offs);
      float const combined_r = PEG_RADIUS + ball->r;

      float const resolution_magnitude = combined_r - diff;
      if (resolution_magnitude < 0) {
        continue;
      }

      const struct vec2 normalized_offs = vec2_normalized(&offs);
      const struct vec2 resolution =
          vec2_mul(&normalized_offs, resolution_magnitude);
      const struct vec2 zero = (struct vec2){
          .x = 0,
          .y = 0,
      };
      apply_ball_collision(ball, &resolution, &normalized_offs, &zero, delta,
                           0.35);
    }
  }
}

size_t last_canvas_width = 0;
size_t last_canvas_height = 0;

void render(size_t canvas_width, size_t canvas_height) {
  if (last_canvas_width == canvas_width &&
      last_canvas_height == canvas_height) {
    return;
  }

  for (int i = 0; i < canvas_width * canvas_height; ++i) {
    canvas_memory[i] = 0xffffffff;
  }

  int i = 0;
  while (true) {
    const struct pos2 loc = pegLoc(i++);
    if (loc.y > PEG_Y_MAX) {
      break;
    }
    float const r_canvas = PEG_RADIUS * canvas_width;
    int const y_center_canvas = canvas_height - loc.y * canvas_width;
    int const x_center_canvas = loc.x * canvas_width;

    for (int y = -r_canvas; y < r_canvas; ++y) {
      int const x_max = __builtin_sqrt(r_canvas * r_canvas - y * y);
      for (int x = -x_max; x < x_max; ++x) {
        int const canvas_y = y_center_canvas + y;
        int const canvas_x = x_center_canvas + x;
        int const idx = canvas_y * canvas_width + canvas_x;
        if (idx >= canvas_width * canvas_height || idx < 0) {
          continue;
        }
        canvas_memory[idx] = 0xff000000;
      }
    }
  }

  last_canvas_width = canvas_width;
  last_canvas_height = canvas_height;
}
