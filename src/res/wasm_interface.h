#include <stddef.h>

/**
 * Called one time in both server and client contexts. max_num_balls or
 * max_canvas_size may be 0, but in some contexts both will be set
 *
 * Use for one time initialization of chamber state, and ensure memory returned
 * by xxxMemory() calls are ready to go
 */
void init(size_t max_num_balls, size_t max_canvas_size);

/**
 * Run physics and update chamber state
 *
 * This is typically run on the server, but in some contexts is also run on the
 * client
 *
 * num balls tells us how many balls have been placed in ballsMemory() by the
 * caller (initialized in init). Delta is the amount of time passed in seconds
 * that we want to simulate in this step
 *
 * Definition of balls is provided by physics.h, or physics.zig
 */
void step(size_t num_balls, float delta);

/**
 * Put pixels into the memory returned by canvasMemory(). Expectation is that
 * the memory has been written such that canvasMemory()[y * canvas_width + x]
 * represents a pixel at (x, y)
 *
 * Pixels are represented as 4 byte chunks of RGBA. Feel free to use a u32 with
 * 0xaabbggrr
 *
 * Note that canavs_width * canvas_height may be less than max_canvas_size, but
 * will never be greater
 *
 * canvasMemory() can be re-used between frames, so free to re-use previous
 * frame data if that is useful to you
 */
void render(size_t canvas_width, size_t canvas_height);

/**
 * Since some code runs on the client, and some code runs on the server, we need
 * a way to propagate our state from one side to the other. The save/load API is
 * how we do this. Take any state from the physics side, serialize it,
 * deserialize with load on the client side before render() is called
 */
void save(void);
void load(void);

/**
 * Pointer to memory where the caller can place balls. Externally we will
 * write up to max_num_balls `struct balls`, so this needs to be large enough to
 * handle that
 */
void* ballsMemory(void);

/**
 * Pointer to memory where the chamber will write pixels to. This needs
 * to be max_canvas_size * 4 bytes long. See render() for more info
 */
void* canvasMemory(void);

/**
 * Pointer to memory where we can interact with save data. Data will be
 * placed here before calling load(), and read from here after calling save()
 *
 * This memory will not be used if saveSize() returns 0
 *
 * See save()/load() for more info
 */
void* saveMemory(void);

/**
 * How many bytes we should use from saveMemory()
 */
size_t saveSize(void);

