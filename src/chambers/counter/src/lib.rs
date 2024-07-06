use std::{
    cell::UnsafeCell,
    mem::MaybeUninit
};
mod physics;

macro_rules! impl_global {
    ($name:ident, $ty:ty) => {
        struct $name {
            inner: UnsafeCell<MaybeUninit<$ty>>
        }

        impl $name {
            const fn new() -> $name {
                $name { inner: UnsafeCell::new(MaybeUninit::uninit()) }
            }

            #[allow(clippy::mut_from_ref)]
            fn get(&self) -> &mut $ty {
                unsafe {
                    &mut *(*self.inner.get()).assume_init_mut()
                }
            }
        }

        unsafe impl Sync for $name {}
    }
}

impl_global!(GlobalBalls, Box<[physics::ball]>);
impl_global!(GlobalCanvas, Box<[u32]>);
impl_global!(GlobalState, State);
impl_global!(GlobalSave, u8);

static BALLS: GlobalBalls = GlobalBalls::new();
static CANVAS: GlobalCanvas = GlobalCanvas::new();
static STATE: GlobalState = GlobalState::new();
static SAVE_MEMORY: GlobalSave = GlobalSave::new();

struct State {
    num_balls: u8,
}

impl State {
    fn new() -> State {
        State {
            num_balls: 0,
        }
    }
}

fn to_canvas(val: f32, canvas_width: usize) -> usize {
    (val * (canvas_width as f32)) as usize
}

fn draw_line(line: Line, canvas_width: usize, canvas: &mut [u32]) {

    match line {
        Line::Horizontal {
            y, start, end,
        } => {
            let y_px = to_canvas(y, canvas_width);
            let start_px = to_canvas(start, canvas_width).saturating_sub(2);
            let end_px = (to_canvas(end, canvas_width) + 2).min(canvas_width);
            for y in y_px.saturating_sub(3)..(y_px + 3) {
                for x in start_px..end_px {
                    canvas[y * canvas_width + x] = 0xff000000;
                }
            }
        },
        Line::Vertical {
            x, start, end,
        } => {
            let x_px = to_canvas(x, canvas_width);
            let start_px = to_canvas(start, canvas_width).saturating_sub(2);
            let end_px = (to_canvas(end, canvas_width) + 2).min(canvas_width);
            for y in start_px..end_px {
                for x in x_px.saturating_sub(3)..(x_px + 3).min(canvas_width) {
                    canvas[y * canvas_width + x] = 0xff000000;
                }
            }
        },
    }
}

#[derive(Clone)]
enum Line {
    Vertical {
        x: f32,
        start: f32,
        end: f32,
    },
    Horizontal {
        y: f32,
        start: f32,
        end: f32,
    },

}

impl Line {
    fn translate(&self, x_offs: f32, y_offs: f32) -> Line {
        let mut ret = self.clone();
        match &mut ret {
            Line::Vertical {ref mut x, ref mut start, ref mut end} => {
                *x += x_offs;
                *start += y_offs;
                *end += y_offs;
            }
            Line::Horizontal {ref mut y, ref mut start, ref mut end} => {
                *y += y_offs;
                *start += x_offs;
                *end += x_offs;
            }
        }
        ret
    }
}

fn render_7seg(val: u8, x_offs: f32, y_offs: f32, canvas_width: usize, canvas: &mut [u32]) {
    //       0
    //     ____
    //    |    |
    //  5 |__6_| 1
    //    |    |
    //  4 |____| 2
    //       3
    //

    const NUMS: [u8; 10] = [
        0b00111111,
        0b00000110,
        0b01011011,
        0b01001111,
        0b01100110,
        0b01101101,
        0b01111101,
        0b00000111,
        0b01111111,
        0b01101111,
    ];

    assert!(val < 10);

    const LINES: [Line; 7] = [
        Line::Horizontal {
            y: 0.0,
            start: 0.0,
            end: 0.1,
        },
        Line::Vertical {
            x: 0.1,
            start: 0.0,
            end: 0.1,
        },
        Line::Vertical {
            x: 0.1,
            start: 0.1,
            end: 0.2,
        },
        Line::Horizontal {
            y: 0.2,
            start: 0.0,
            end: 0.1,
        },
        Line::Vertical {
            x: 0.0,
            start: 0.1,
            end: 0.2,
        },
        Line::Vertical {
            x: 0.0,
            start: 0.0,
            end: 0.1,
        },
        Line::Horizontal {
            y: 0.1,
            start: 0.0,
            end: 0.1,
        },
    ];

    let mut bitset = NUMS[val as usize];
    for line in LINES {
        if bitset & 1 == 1 {
            draw_line(line.translate(x_offs, y_offs), canvas_width, canvas);
        }
        bitset >>= 1;
    }
}


extern {
    #[allow(unused)]
    fn logWasm(s: *const core::ffi::c_char, len: usize);
}

#[no_mangle]
pub fn init(max_balls: usize, max_chamber_pixels: usize) {
    let v = vec![physics::ball {
        pos: physics::pos2 {
            x: 0f32,
            y: 0f32,
        },
        r: 0f32,
        velocity: physics::vec2 {
            x: 0f32,
            y: 0f32,
        }
    }; max_balls];

    let balls_ptr = BALLS.inner.get();
    unsafe {
        (*balls_ptr).write(v.into_boxed_slice());
    }

    let v = vec![0u32; max_chamber_pixels];
    let canvas_ptr = CANVAS.inner.get();
    unsafe {
        (*canvas_ptr).write(v.into_boxed_slice());
    }

    let state_ptr = STATE.inner.get();
    unsafe {
        (*state_ptr).write(State::new());
    }
}

#[no_mangle]
#[allow(non_snake_case)]
pub fn canvasMemory() -> *const u32 {
    CANVAS.get().as_ptr()
}

#[no_mangle]
#[allow(non_snake_case)]
pub fn ballsMemory() -> *const physics::ball {
    BALLS.get().as_ptr()
}

#[no_mangle]
#[allow(non_snake_case)]
pub fn saveMemory() -> *const u8 {
    SAVE_MEMORY.get() as *const u8
}

#[no_mangle]
#[allow(non_snake_case)]
pub fn saveSize() -> usize {
    1
}

#[no_mangle]
pub fn save() {
    let save = SAVE_MEMORY.get();
    let state = STATE.get();
    *save = state.num_balls;
}

#[no_mangle]
pub fn load() {
    let save = SAVE_MEMORY.get();
    let state = STATE.get();
    state.num_balls = *save;
}

#[no_mangle]
pub fn step(num_balls: usize, delta: f32) {
    let balls = &mut BALLS.get()[0..num_balls];
    let state = STATE.get();

    let surface = physics::surface {
        a: physics::pos2 {
            x: 0f32,
            y: 0f32,
        },
        b: physics::pos2 {
            x: 1f32,
            y: 0f32,
        }
    };

    for ball in balls {
        let mut ball_collision_point = ball.pos;
        ball_collision_point.y -= ball.r;

        unsafe {
            let mut resolution = MaybeUninit::uninit();
            let collided = physics::surface_collision_resolution(
                &surface,
                &ball_collision_point,
                &physics::vec2_mul(&ball.velocity, delta),
                resolution.as_mut_ptr());

            let zero = physics::vec2 {
                x: 0.0,
                y: 0.0,
            };
            if collided {
                physics::apply_ball_collision(ball as *mut physics::ball, resolution.assume_init_ref(), &physics::surface_normal(&surface), &zero, delta, 0.9);
            }

            physics::surface_push_if_colliding(&surface, ball as *mut physics::ball, delta);
        }
    }

    state.num_balls = num_balls.min(255) as u8;
}

#[no_mangle]
pub fn render(canvas_width: usize, canvas_height: usize) {
    let state = STATE.get();
    let canvas = CANVAS.get();
    canvas[0..canvas_width * canvas_height].fill(0xffffffff);

    render_7seg(state.num_balls % 10, 0.60, 0.2, canvas_width, canvas);
    render_7seg((state.num_balls / 10) % 10, 0.45, 0.2, canvas_width, canvas);
    render_7seg((state.num_balls / 100) % 10, 0.30, 0.2, canvas_width, canvas);
}
