/* Runs INSIDE a Linux guest on virtio-gpu (virgl): uploads 1-channel textures
 * the way Skia's glyph atlas does and reads them back through a draw.
 *   gcc guest-r8-test.c -o r8 -lEGL -lGLESv2 -lgbm && ./r8 */
#include <stdio.h>
#include <fcntl.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

static GLuint prog;
static void draw_and_read(GLuint tex, const char *what, int use_alpha) {
    GLuint rt, fb; unsigned char out[4] = {9, 9, 9, 9};
    glGenTextures(1, &rt); glBindTexture(GL_TEXTURE_2D, rt);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0);
    glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
    glViewport(0, 0, 4, 4); glClearColor(0.5, 0.5, 0.5, 0.5); glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "a"), use_alpha);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, out);
    printf("R8TEST %-34s -> %3d %3d %3d %3d  err=0x%x  %s\n", what, out[0], out[1], out[2], out[3],
           glGetError(), (out[0] == 200 || out[3] == 200) ? "OK" : "BROKEN");
}

static GLuint sh(GLenum t, const char *s) { GLuint h = glCreateShader(t); glShaderSource(h, 1, &s, 0); glCompileShader(h); return h; }

int main(void) {
    int fd = open("/dev/dri/renderD128", O_RDWR);
    struct gbm_device *g = gbm_create_device(fd);
    EGLDisplay d = eglGetPlatformDisplay(EGL_PLATFORM_GBM_MESA, g, NULL);
    eglInitialize(d, 0, 0); eglBindAPI(EGL_OPENGL_ES_API);
    EGLint xa[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
    EGLContext x = eglCreateContext(d, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, xa);
    eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, x);
    printf("R8TEST renderer: %s\n", glGetString(GL_RENDERER));
    prog = glCreateProgram();
    glAttachShader(prog, sh(GL_VERTEX_SHADER, "#version 300 es\nvoid main(){vec2 v[3]=vec2[](vec2(-1,-1),vec2(3,-1),vec2(-1,3));gl_Position=vec4(v[gl_VertexID],0,1);}"));
    glAttachShader(prog, sh(GL_FRAGMENT_SHADER, "#version 300 es\nprecision mediump float;uniform sampler2D t;uniform int a;out vec4 o;void main(){vec4 c=texture(t,vec2(0.5));o=a==1?vec4(c.a):vec4(c.r);}"));
    glLinkProgram(prog);

    unsigned char px[64 * 64]; for (int i = 0; i < 64 * 64; i++) px[i] = 200;
    GLuint t; glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    /* 1: R8, glTexImage2D with data */
    glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 64, 64, 0, GL_RED, GL_UNSIGNED_BYTE, px);
    draw_and_read(t, "R8 TexImage2D(data)", 0);

    /* 2: R8, TexStorage + TexSubImage with ROW_LENGTH (Skia atlas upload) */
    glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_R8, 64, 64);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 64);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 64, 64, GL_RED, GL_UNSIGNED_BYTE, px);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 3, 5, 13, 7, GL_RED, GL_UNSIGNED_BYTE, px);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    draw_and_read(t, "R8 TexStorage+TexSubImage", 0);

    /* 3: legacy A8 (GL_ALPHA), sampled .a */
    glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, 64, 64, 0, GL_ALPHA, GL_UNSIGNED_BYTE, px);
    draw_and_read(t, "ALPHA8 TexImage2D(data)", 1);

    /* 4: RGBA8 control */
    unsigned char rgba[16 * 16 * 4]; for (int i = 0; i < 16 * 16 * 4; i++) rgba[i] = 200;
    glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    draw_and_read(t, "RGBA8 control", 0);
    return 0;
}
