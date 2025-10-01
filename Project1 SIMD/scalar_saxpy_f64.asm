0000000000006b90 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)>:
    6b90:	f3 0f 1e fa          	endbr64
    6b94:	48 85 d2             	test   rdx,rdx
    6b97:	74 28                	je     6bc1 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0x31>
    6b99:	31 c0                	xor    eax,eax
    6b9b:	48 83 f9 01          	cmp    rcx,0x1
    6b9f:	75 27                	jne    6bc8 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0x38>
    6ba1:	0f 1f 80 00 00 00 00 	nop    DWORD PTR [rax+0x0]
    6ba8:	c5 fb 10 0c c7       	vmovsd xmm1,QWORD PTR [rdi+rax*8]
    6bad:	c4 e2 f9 a9 0c c6    	vfmadd213sd xmm1,xmm0,QWORD PTR [rsi+rax*8]
    6bb3:	c5 fb 11 0c c6       	vmovsd QWORD PTR [rsi+rax*8],xmm1
    6bb8:	48 83 c0 01          	add    rax,0x1
    6bbc:	48 39 d0             	cmp    rax,rdx
    6bbf:	75 e7                	jne    6ba8 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0x18>
    6bc1:	c3                   	ret
