import math, sys
from PIL import Image, ImageDraw
VERDE=(0x0F,0x5C,0x4D,255); CREMA=(0xF6,0xF4,0xEF,255); NAR=(0xE8,0x74,0x2A,255); TINTA=(0x1C,0x1B,0x19,255)
K=4
def lienzo(n, fondo, lleno):
    S=n*K; im=Image.new('RGBA',(S,S),fondo if lleno else (0,0,0,0)); d=ImageDraw.Draw(im)
    if not lleno: d.rounded_rectangle([0,0,S-1,S-1],radius=int(S*0.225),fill=fondo)
    return im,d,S
def fin(im,n): return im.resize((n,n),Image.LANCZOS)

def campana(n, lleno=False, e=1.0):
    im,d,S=lienzo(n,VERDE,lleno); u=S/100*e; cx=S/2; oy=S/2-50*u
    y=lambda v: oy+v*u; x=lambda v: cx+(v-50)*u
    r=27
    d.pieslice([x(50-r),y(60-r),x(50+r),y(60+r)],180,360,fill=CREMA)      # cúpula
    d.rounded_rectangle([x(16),y(64),x(84),y(71)],radius=3.5*u,fill=CREMA)  # bandeja
    d.ellipse([x(45),y(23),x(55),y(33)],fill=NAR)                          # pomo
    # brillo
    d.arc([x(50-r+7),y(60-r+7),x(50+r-7),y(60+r-7)],200,250,fill=VERDE,width=int(3.2*u))
    return fin(im,n)

def ticket(n, lleno=False, e=1.0):
    im,d,S=lienzo(n,VERDE,lleno); u=S/100*e; cx=S/2; oy=S/2-50*u
    y=lambda v: oy+v*u; x=lambda v: cx+(v-50)*u
    d.rounded_rectangle([x(28),y(20),x(72),y(60)],radius=5*u,fill=CREMA)
    pts=[(x(28),y(50)),(x(72),y(50))]
    dientes=4; w=44/dientes
    pts+= [(x(72),y(74))]
    for i in range(dientes):
        pts+=[(x(72-w*i-w/2),y(80)),(x(72-w*(i+1)),y(74))]
    pts+=[(x(28),y(50))]
    d.polygon(pts,fill=CREMA)
    for yy,x2 in ((32,64),(42,56)):
        d.rounded_rectangle([x(36),y(yy),x(x2),y(yy+4.5)],radius=2.2*u,fill=VERDE)
    d.rounded_rectangle([x(36),y(56),x(64),y(62.5)],radius=3*u,fill=NAR)
    return fin(im,n)

def plato(n, lleno=False, e=1.0):
    im,d,S=lienzo(n,TINTA,lleno); u=S/100*e; cx=S/2; cy=S/2
    R=30*u; g=9.5*u
    d.arc([cx-R,cy-R,cx+R,cy+R],40,325,fill=CREMA,width=int(g))
    # extremos redondeados
    for a in (40,325):
        px=cx+(R-g/2)*math.cos(math.radians(a)); py=cy+(R-g/2)*math.sin(math.radians(a))
        d.ellipse([px-g/2,py-g/2,px+g/2,py+g/2],fill=CREMA)
    d.rounded_rectangle([cx-1*u,cy-g/2+1.5*u,cx+R+0*u,cy+g/2+1.5*u],radius=g/2,fill=NAR)
    return fin(im,n)

def _degradado(S, c1, c2):
    g=Image.new('RGBA',(S,S)); p=g.load()
    for yy in range(S):
        for xx in range(0,S):
            t=(xx+yy)/(2*S-2)
            p[xx,yy]=tuple(int(c1[i]+(c2[i]-c1[i])*t) for i in range(3))+(255,)
    return g

def plato2(n, lleno=False, e=1.0, fondo='verde'):
    """Plato-G con más cuerpo: fondo de color con degradado y trazo grueso (se lee en la barra de tareas)."""
    S=n*K
    c1,c2={'verde':((0x18,0x8A,0x70),(0x0A,0x45,0x3A)),'naranja':((0xF5,0x8E,0x3F),(0xD9,0x5C,0x16))}[fondo]
    g=_degradado(S,c1,c2)
    mask=Image.new('L',(S,S),255 if lleno else 0)
    if not lleno: ImageDraw.Draw(mask).rounded_rectangle([0,0,S-1,S-1],radius=int(S*0.225),fill=255)
    im=Image.new('RGBA',(S,S),(0,0,0,0)); im.paste(g,(0,0),mask); d=ImageDraw.Draw(im)
    u=S/100*e; cx=S/2-1.5*u; cy=S/2
    trazo=CREMA if fondo=='verde' else TINTA; barra=NAR if fondo=='verde' else CREMA
    R=33*u; gr=13.5*u
    d.arc([cx-R,cy-R,cx+R,cy+R],42,322,fill=trazo,width=int(gr))
    for a in (42,322):
        px=cx+(R-gr/2)*math.cos(math.radians(a)); py=cy+(R-gr/2)*math.sin(math.radians(a))
        d.ellipse([px-gr/2,py-gr/2,px+gr/2,py+gr/2],fill=trazo)
    d.rounded_rectangle([cx-2*u,cy-gr/2+2*u,cx+R+3*u,cy+gr/2+2*u],radius=gr/2,fill=barra)
    return fin(im,n)
