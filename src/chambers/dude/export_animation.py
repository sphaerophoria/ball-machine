import bpy
from pathlib import Path
import sys
import subprocess


def find_output_arg():
    for i in range(0, len(sys.argv)):
        if sys.argv[i] == "--":
            return sys.argv[i + 1]


def main(output_path):
    bpy.ops.wm.open_mainfile(filepath=str(Path(__file__).parent / "dude.blend"))

    f = open(output_path, "w")

    arm = bpy.data.objects["Armature"]

    f.write(
        """
        const physics = @import("physics");
        const Pos2 = physics.Pos2;

        pub const Bone = struct {
           a: Pos2,
           b: Pos2,
        };

        pub const Keyframe = struct {
           t: f32,
           bone: Bone,
        };

        pub const Animation = []const Keyframe;

        pub const objects: []const Animation = &.{"""
    )

    fcurves = arm.animation_data.action.fcurves

    for bone in arm.pose.bones:
        f.write("&.{")
        bone_keyframes = set()

        for fcurve in fcurves:
            if fcurve.data_path.startswith(f'pose.bones["{bone.name}"]'):
                for keyframe in fcurve.keyframe_points:
                    bone_keyframes.add(int(keyframe.co[0]))

        for frame in bone_keyframes:
            bpy.context.scene.frame_set(frame)

            f.write(
                """.{{
                .t = {},
                .bone = .{{
                    .a = .{{
                      .x = {},
                      .y = {},
                    }},
                   .b = .{{
                      .x = {},
                      .y = {},
                   }},
                }},
            }},""".format(
                    frame,
                    bone.head[0],
                    bone.head[1],
                    bone.tail[0],
                    bone.tail[1],
                )
            )
        f.write("},")

    f.write(
        """
    };"""
    )

    f.close()

    subprocess.run(["zig", "fmt", output_path])


main(find_output_arg())
