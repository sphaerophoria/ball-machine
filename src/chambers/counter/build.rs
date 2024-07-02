use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rustc-link-search=../../../zig-out/lib");
    println!("cargo:rustc-link-lib=physics");

    let bindings = bindgen::Builder::default()
        .header("physics.h")
        .use_core()
        .clang_arg("-fvisibility=default")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("physics.rs"))
        .expect("Couldn't write bindings!");
}
