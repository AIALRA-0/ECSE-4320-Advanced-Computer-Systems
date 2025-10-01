0000000000007000 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)>:
    7000:	f3 0f 1e fa          	endbr64
    7004:	48 85 d2             	test   rdx,rdx
    7007:	74 44                	je     704d <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0x4d>
    7009:	48 83 f9 01          	cmp    rcx,0x1
    700d:	0f 85 dd 00 00 00    	jne    70f0 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0xf0>
    7013:	48 83 fa 01          	cmp    rdx,0x1
    7017:	0f 84 c3 00 00 00    	je     70e0 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0xe0>
    701d:	48 8d 47 08          	lea    rax,[rdi+0x8]
    7021:	48 89 f1             	mov    rcx,rsi
    7024:	48 29 c1             	sub    rcx,rax
    7027:	31 c0                	xor    eax,eax
    7029:	48 83 f9 10          	cmp    rcx,0x10
    702d:	77 21                	ja     7050 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0x50>
    702f:	90                   	nop
    7030:	c5 fb 10 0c c7       	vmovsd xmm1,QWORD PTR [rdi+rax*8]
    7035:	c4 e2 f9 a9 0c c6    	vfmadd213sd xmm1,xmm0,QWORD PTR [rsi+rax*8]
    703b:	c5 fb 11 0c c6       	vmovsd QWORD PTR [rsi+rax*8],xmm1
    7040:	48 83 c0 01          	add    rax,0x1
    7044:	48 39 c2             	cmp    rdx,rax
    7047:	75 e7                	jne    7030 <void kernel_saxpy<double>(double, double const*, double*, unsigned long, unsigned long)+0x30>
    7049:	c3                   	ret
