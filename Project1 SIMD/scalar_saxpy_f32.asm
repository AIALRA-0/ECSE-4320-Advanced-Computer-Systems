0000000000006980 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)>:
    6980:	f3 0f 1e fa          	endbr64
    6984:	48 85 d2             	test   rdx,rdx
    6987:	74 28                	je     69b1 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x31>
    6989:	31 c0                	xor    eax,eax
    698b:	48 83 f9 01          	cmp    rcx,0x1
    698f:	75 27                	jne    69b8 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x38>
    6991:	0f 1f 80 00 00 00 00 	nop    DWORD PTR [rax+0x0]
    6998:	c5 fa 10 0c 87       	vmovss xmm1,DWORD PTR [rdi+rax*4]
    699d:	c4 e2 79 a9 0c 86    	vfmadd213ss xmm1,xmm0,DWORD PTR [rsi+rax*4]
    69a3:	c5 fa 11 0c 86       	vmovss DWORD PTR [rsi+rax*4],xmm1
    69a8:	48 83 c0 01          	add    rax,0x1
    69ac:	48 39 d0             	cmp    rax,rdx
    69af:	75 e7                	jne    6998 <void kernel_saxpy<float>(float, float const*, float*, unsigned long, unsigned long)+0x18>
    69b1:	c3                   	ret
