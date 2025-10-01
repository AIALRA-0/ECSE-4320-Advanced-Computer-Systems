0000000000006940 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)>:
    6940:	f3 0f 1e fa          	endbr64
    6944:	48 85 d2             	test   rdx,rdx
    6947:	74 4c                	je     6995 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x55>
    6949:	48 83 f9 01          	cmp    rcx,0x1
    694d:	0f 85 3d 01 00 00    	jne    6a90 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x150>
    6953:	48 8d 4a ff          	lea    rcx,[rdx-0x1]
    6957:	48 83 f9 02          	cmp    rcx,0x2
    695b:	0f 86 27 01 00 00    	jbe    6a88 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x148>
    6961:	48 8d 47 04          	lea    rax,[rdi+0x4]
    6965:	49 89 f0             	mov    r8,rsi
    6968:	49 29 c0             	sub    r8,rax
    696b:	31 c0                	xor    eax,eax
    696d:	49 83 f8 18          	cmp    r8,0x18
    6971:	77 2d                	ja     69a0 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x60>
    6973:	0f 1f 44 00 00       	nop    DWORD PTR [rax+rax*1+0x0]
    6978:	c5 fa 10 0c 87       	vmovss xmm1,DWORD PTR [rdi+rax*4]
    697d:	c4 e2 79 a9 0c 86    	vfmadd213ss xmm1,xmm0,DWORD PTR [rsi+rax*4]
    6983:	c5 fa 11 0c 86       	vmovss DWORD PTR [rsi+rax*4],xmm1
    6988:	48 83 c0 01          	add    rax,0x1
    698c:	48 39 c2             	cmp    rdx,rax
    698f:	75 e7                	jne    6978 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x38>
    6991:	c3                   	ret
