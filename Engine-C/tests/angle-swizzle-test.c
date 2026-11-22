/* Does ANGLE (Metal) honour GL_TEXTURE_SWIZZLE on an R8 texture? virglrenderer
 * maps guest A8 (glyph atlases) to R8 + swizzle (0,0,0,R) on GLES hosts. */
#include <stdio.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
static GLuint sh(GLenum t, const char *s) { GLuint h = glCreateShader(t); glShaderSource(h, 1, &s, 0); glCompileShader(h); return h; }
int main(void) {
    EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY); eglInitialize(d, 0, 0); eglBindAPI(EGL_OPENGL_ES_API);
    EGLint ca[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE }, n; EGLConfig c;
    eglChooseConfig(d, ca, &c, 1, &n);
    EGLint xa[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext x = eglCreateContext(d, c, EGL_NO_CONTEXT, xa); eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, x);
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    unsigned char px[4] = { 200, 200, 200, 200 };
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 2, 2, 0, GL_RED, GL_UNSIGNED_BYTE, px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    GLint sw[4] = { GL_ZERO, GL_ZERO, GL_ZERO, GL_RED };
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, sw[0]); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_G, sw[1]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, sw[2]); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, sw[3]);
    GLuint rt; glGenTextures(1, &rt); glBindTexture(GL_TEXTURE_2D, rt);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0);
    GLuint fb; glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
    GLuint p = glCreateProgram();
    glAttachShader(p, sh(GL_VERTEX_SHADER, "#version 300 es\nvoid main(){vec2 v[3]=vec2[](vec2(-1,-1),vec2(3,-1),vec2(-1,3));gl_Position=vec4(v[gl_VertexID],0,1);}"));
    glAttachShader(p, sh(GL_FRAGMENT_SHADER, "#version 300 es\nprecision mediump float;uniform sampler2D t;out vec4 o;void main(){o=texture(t,vec2(0.5));}"));
    glLinkProgram(p); glUseProgram(p);
    glViewport(0, 0, 4, 4); glClearColor(1, 1, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    unsigned char out[4]; glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, out);
    printf("sampled RGBA = %d %d %d %d   (expected 0 0 0 200)\n", out[0], out[1], out[2], out[3]);
    printf("glGetError = 0x%x\n", glGetError());
    return !(out[0] == 0 && out[3] == 200);
}
