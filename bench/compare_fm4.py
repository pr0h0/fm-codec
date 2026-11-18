import subprocess, time, os, sys, json
F=os.path.expanduser('~/Projects/fm-codec'); T=F+'/testdata/'
os.system(f"head -c 1000000 {T}bin_10mb.bin > in/bin1m; head -c $((640*360*3*4)) {T}media/v3_640x360x10.rgb > in/v3x4.rgb; head -c $((640*360*3*4)) {T}media/v4_640x360x10.rgb > in/v4x4.rgb")
files=[ # label, path, mode, args
 ('TypeScript source 1 MB',T+'corpus/ts.txt','bytes',[]),
 ('Markdown 1 MB',T+'corpus/md.txt','bytes',[]),
 ('JSON 1 MB',T+'corpus/json.txt','bytes',[]),
 ('Binary 1 MB','in/bin1m','bytes',[]),
 ('Photo 640x426',T+'corpus/img16_jpg_640.rgb','image',[640]),
 ('Graphic 360x835',T+'corpus/img4_png_360.rgb','image',[360]),
 ('Speech 24 kHz mono',T+'media/a0_wav_24000_1.pcm','audio',[1]),
 ('Recording 48 kHz stereo',T+'media/a8_wav_48000_2.pcm','audio',[2]),
 ('Video animation 4 frames','in/v3x4.rgb','video',[640,360]),
 ('Video camera 4 frames','in/v4x4.rgb','video',[640,360]),
]
def run(cmd, out):
    if os.path.exists(out): os.remove(out)
    t=time.time(); r=subprocess.run(cmd,shell=True,capture_output=True); dt=time.time()-t
    if r.returncode or not os.path.exists(out): print('FAIL',cmd,r.stderr[-300:],file=sys.stderr); return None
    return os.path.getsize(out), dt
res={}
for label,p,mode,a in files:
    L=os.path.getsize(p); A=' '.join(map(str,a)); o='out/x'; row={}
    row['fm4 C']=run(f"{F}/c/fm4 enc 4 {mode} {A} {p} out/c",'out/c')
    row['fm4 BPL']=run(f"{F}/bpl/fm4 enc 4 {mode} {A} {p} out/b",'out/b')
    row['fm4 wasm']=run(f"node w.mjs {p} out/w {mode} {A}",'out/w')
    same = open('out/c','rb').read()==open('out/b','rb').read()==open('out/w','rb').read()
    t=time.time(); subprocess.run(f"{F}/c/fm4 dec out/c out/d",shell=True); dect=time.time()-t
    rt = open('out/d','rb').read()==open(p,'rb').read()
    row['gzip -9']=run(f"gzip -9 -c {p} > {o}",o)
    row['bzip2 -9']=run(f"bzip2 -9 -c {p} > {o}",o)
    row['zstd -19']=run(f"zstd -19 -q -c {p} > {o}",o)
    row['xz -9e']=run(f"xz -9e -T1 -c {p} > {o}",o)
    ff="ffmpeg -v error -y "
    if mode=='image':
        h=L//(3*a[0]); i=f"-f rawvideo -pix_fmt rgb24 -s {a[0]}x{h} -i {p}"
        row['PNG']=run(ff+i+" -compression_level 9 out/x.png",'out/x.png')
        row['WebP lossless']=run(ff+i+" -lossless 1 -compression_level 6 -quality 100 out/x.webp",'out/x.webp')
    if mode=='audio':
        i=f"-f s16le -ar 48000 -ac {a[0]} -i {p}"
        row['FLAC (level 12)']=run(ff+i+" -compression_level 12 out/x.flac",'out/x.flac')
    if mode=='video':
        i=f"-f rawvideo -pix_fmt rgb24 -s {a[0]}x{a[1]} -r 25 -i {p}"
        row['H.264 lossless']=run(ff+i+" -c:v libx264rgb -qp 0 -preset veryslow out/x.mkv",'out/x.mkv')
        row['H.265 lossless']=run(ff+i+" -c:v libx265 -pix_fmt gbrp -x265-params lossless=1:log-level=error -preset slow out/y.mkv",'out/y.mkv')
        row['FFV1']=run(ff+i+" -c:v ffv1 -level 3 -context 1 -g 600 out/z.mkv",'out/z.mkv')
    res[label]={'L':L,'same':same,'rt':rt,'dec':dect,'rows':row}
    print(label,L,'identical' if same else 'DIFFER','rt' if rt else 'RT-FAIL',f"dec {dect:.2f}",flush=True)
    for k,v in row.items(): print(f"   {k:18s} {v[0]/L:.4f} {v[1]:.2f}s" if v else f"   {k} FAIL",flush=True)
json.dump(res,open('res.json','w'))
