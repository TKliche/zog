'********************************************************************************
'*                                                                              *
'* ZOG_SMALL A ZPU Virtual machine running on the Parallax Propeller            *
'*           micro-controller.                                                  *
'*                                                                              *
'*           ZOG_JIT is a compact version of ZOG that compiles (at run time!)   *
'*           the ZPU instructions to native Propeller instructions. It is based *
'*           on Michael Rychlik's ZOG_SMALL, but it's been extensively          *
'*           modified by me (Eric Smith) and is, alas, much uglier now          *
'*                                                                              *
'* What?     The ZPU is a 32 bit processor core architecture specified by ZyLin *
'*           consultants for which there a number of HDL implementations        *
'*           for FPGA's.                                                        *
'*                                                                              *
'* Why?      ZyLin have targeted the GNU C Compiler to the ZPU instruction set. *
'*           ZOG makes it possible to use GCC for Propeller development.        *
'*           All ZPU instructions are a single byte, which should work out      *
'*           nicely when the code is placed in external RAM with an 8 bit bus.  *
'*                                                                              *
'*           Based on an original idea by Toby Seckshund.                       *
'*           Maths routines courtesy of Cluso and Parallax.                     *
'*                                                                              *
'*           Encouragement courtesy of Bill Henning and all on the Parallax     *
'*           Propeller discussion forum.                                        *
'*                                                                              *
'* Authors:  Eric Smith, Michael Rychlik                                        *
'*                                                                              *
'********************************************************************************
'
' v0.2      2017-04-06 First zog 1.6 compatible version (original development
'                      was based on zog 1.0)
'
' Michael's original change log below:
'
' v0.1      09-02-2010 First draft, totally untested.
'
' v0.2      18-02-2010 Tested and fixed up initial bugs.
'                      Runs first test program compiled with GCC.
'                      Has no I/O yet.
'
' v0.3      19-02-2010 Fixed mysterious "inversion of bit four of offset" problem
'                      with LOADSP and STORESP.
'
' v0.4      20-02-2010 Added primitive UART output such that the C run time
'                      routine outbyte() works. Zog now says hello!
'
' v0.5      28-02-2010 The CONFIG instruction is now always emulated,
'                      see emulate code in libgloss crt0.S for why.
'                      Added handling of the SYSCALL instruction via the io_command trap mechainism.
'                      Added fsrwFemto object (inititialization calls commented out for now).
'
' v0.6      xx-03-2010 Changed UART object to FullDuplexSerialPlus.
'
' v0.8      18-04-2010 Rewrote all ops with optimizations as suggested by Bill Henning.
'
' v0.9      25-04-2010 Optimized some most used ops in the FIBO test (wink, wink:)
'                      Fixed PUSHSP.
'
' v0.11     09-05-2010 Changes endianess of bytecodes in zpu_memory
'                      Adjusted read/write byte/word and instruction fetch inline with endianness
'                      Fixed ADDSP.
'
' v0.12     11-05-2010 The ZPU_EMULATE op now works. If it's ever needed.
'                      Fixed MOD and DIV instructions.
'                      Inlined read/write_byte
'                      read/write_word are EMULLATED for now as their endiannes is not right yet.
'                      ZPU memory is 20K bytes (Until we put SD and VM COG back in).

' v0.13     19-05-2010 Fixed endiannes of strings output by SYS_write syscall.
'                      Return a zero result from SYS_fstat syscall.
'                      Note: ZOG_SMAL is created for the first time from v0.13 of ZOG
'
' v0.14     08-06-2010 Take Bill Henning's VMCog into use for external RAM access.
'                      Added #ifdef USE_VIRTUAL_MEMORY
'
' v0.15     08-06-2010 Fixed zpu_addsp to work correctly with virtual mem read_long.
'
' The "test.bin" file included in the ZPU memory area is created with
' GCC for the ZPU.
'
' Please see the Makefile included with Zog for how to build C programs
' with GCC for the ZPU architecture that Zog can run.
'
'#define SINGLE_STEP
'#define CYCLE_COUNT

CON
' cache configuration
' CACHE_LINE_SIZE must be a power of 2
' 4 or 8 is probably good if we expect a lot of misses
'' define TWO_LINE_CACHE for a 2 way cache
'' otherwise we have only a single line
#define TWO_LINE_CACHE
'CACHE_LINE_SIZE = 16
CACHE_LINE_SIZE = 32

'CACHE_LINE_SIZE = 64
CACHE_LINE_MASK = (CACHE_LINE_SIZE-1)

' These are the SPIN byte codes for mul and div
SPIN_MUL_OP     = $F4  '(multiply, return lower 32 bits)
SPIN_DIV_OP     = $F6  '(divide, return quotient 32 bits)
SPIN_REM_OP     = $F7  '(divide, return remainder 32 bits)

'I/O control block commands
io_cmd_out      = $01
io_cmd_in       = $02
io_cmd_break    = $03
io_cmd_syscall  = $04

VAR
  long cog
  
PUB start (params) : okay
  okay := cog := cognew(@enter, params) + 1                  'Start emulator in a new COG

PUB stop
'' Stop CPU simulator - frees a cog
  if cog
    cogstop(cog~ - 1)

PUB getdispatch_table
  return @dispatch_table

PUB getzog
  return @enter

DAT

{{
    JIT ZPU Compiler Theory of Operation

    We read a whole cache line from the HUB's ZPU memory at a time,
    and convert the ZPU instructions to Prop instructions which we
    then execute.  The general idea is that every ZPU bytecode is
    expanded to exactly two Propeller instructions (so we can easily
    map branch addresses).  Some ZPU instructions need more; in that
    case one of the translated Prop instructions will be a subroutine
    call to a resident routine.

}}
    
			long
dispatch_table

' This is not a traditional jmp table, it's an indirect one.
' The bottom 9 bits (the source field) encodes the destination for
' the jump, but the other bits can also encode information about
' the instruction as well.
' The whole 32 bits is placed in the aux_opcode register for use
' by the compilation code
'
' The bottom 9 bits (source) is always used and contains the address of
' the routine to compile this instruction to Prop mode
' the next 9 bits (dest) is usually some kind of argument to the routine
' for example, the emit_literal2 routine just copies 2 instructions
' from the pattern encoded in dest into the cache, without having to
' patch it any further. This is a pretty common way to do things.
'
' The instruction field is also used by some compilation routines. For
' example, in the emit_binaryop we use it to decide which opcode to
' insert into cache. A lot of the compiler routines ignore this, though,
' I use "cmp" as the generic default instruction because it stands for
' "compiler", but I suppose whichever opcode is 0 would have made sense
' too.
'
' Naming convention:
'  pat_xxx is the pattern for instruction xxx, and is copied directly to the cache
'  imp_xxx is any local subroutine called by pat_xxx
'
{00}                    cmp     pat_breakpoint, #emit_literal2	' compile zpu_breakpoint
{01}                    cmp     pat_illegal,    #emit_literal2	' compile zpu_illegal
{02}                    cmp     pat_pushsp,     #emit_literal2	' compile zpu_pushsp
{03}                    cmp     pat_illegal,    #emit_literal2	' compile zpu_illegal
{04}                    cmp     pat_poppc,      #emit_literal2	' compile zpu_poppc
{05}                    add     0, #emit_binaryop		' compile zpu_add
{06}                    and     0, #emit_binaryop		' compile zpu_and
{07}                    or      0, #emit_binaryop		' compile zpu_or
{08}                    cmp     pat_load, #emit_literal2		' compile zpu_load
{09}                    cmp	pat_not,  #emit_literal2		' compile zpu_not
{0A}                    cmp     pat_flip, #emit_literal2		' compile zpu_flip
{0B}                    cmp     pat_nop,  #emit_literal2		' compile zpu_nop
{0C}                    cmp     pat_store, #emit_literal2	' compile zpu_store
{0C}                    cmp     pat_popsp, #emit_literal2	' compile zpu_popsp
{0E}                    cmp     pat_illegal, #emit_literal2	' compile zpu_illegal
{0F}                    cmp     pat_illegal, #emit_literal2	' compile zpu_illegal

{10}                    cmp     pat_addsp0, #emit_literal2	' compile zpu_addsp with 0 offset
{11}                    cmp     0, #emit_addsp
{12}                    cmp     0, #emit_addsp
{13}                    cmp     0, #emit_addsp
{14}                    cmp     0, #emit_addsp
{15}                    cmp     0, #emit_addsp
{16}                    cmp     0, #emit_addsp
{17}                    cmp     0, #emit_addsp
{18}                    cmp     0, #emit_addsp
{19}                    cmp     0, #emit_addsp
{1A}                    cmp     0, #emit_addsp
{1B}                    cmp     0, #emit_addsp
{1C}                    cmp     0, #emit_addsp
{1D}                    cmp     0, #emit_addsp
{1E}                    cmp     0, #emit_addsp
{1F}                    cmp     0, #emit_addsp

{20}                    cmp     0, #emit_emulate ' reset??
{21}                    cmp     0, #emit_emulate ' interrupt??
{22}                    cmp     0, #emit_emulate ' loadh
{23}                    cmp     0, #emit_emulate ' storeh
{24}        if_b        cmp     imp_cmp_signed,   #emit_cmp ' lessthan
{25}        if_be       cmp     imp_cmp_signed,   #emit_cmp ' lessthanorequal
{26}        if_b        cmp     imp_cmp_unsigned, #emit_cmp ' ulessthan
{27}        if_be       cmp     imp_cmp_unsigned, #emit_cmp ' ulessthanorequal
{28}                    cmp     0, #emit_emulate ' swap
{29}                    cmp     0, #emit_emulate ' slowmult
{2A}                    shr     0, #emit_binaryop ' lshiftright
{2B}                    shl     0, #emit_binaryop ' ashiftleft
{2C}                    sar     0, #emit_binaryop ' ashiftright
{2D}                    cmp     0, #emit_emulate ' call
{2E}        if_z        cmp     imp_cmp_unsigned, #emit_cmp ' eq
{2F}        if_nz       cmp     imp_cmp_unsigned, #emit_cmp ' neq

{30}                    cmp     pat_neg, #emit_literal2	' compile zpu_neg
{31}                    sub     0, #emit_binaryop ' sub
{32}                    xor     0, #emit_binaryop ' xor
{33}                    cmp     0, #emit_emulate ' loadb
{34}                    cmp     0, #emit_emulate ' storeb
{35}                    cmp     0, #emit_emulate ' div
{36}                    cmp     0, #emit_emulate ' mod
{37}        if_z        cmp     0, #emit_condbranch ' eqbranch
{38}        if_nz       cmp     0, #emit_condbranch ' neqbranch
{39}                    cmp     0, #emit_emulate ' poppcrel
{3A}                    cmp     0, #emit_emulate ' config
{3B}                    cmp     pat_pushpc, #emit_literal2	' compile pushpc
'''{3C}                    cmp     pat_syscall, #emit_literal2 	' compile syscall
{3C}                    cmp     pat_breakpoint, #emit_literal2 	' compile syscall
{3D}                    cmp     pat_pushspadd,  #emit_literal2  ' compile pushspadd
{3E}                    cmp     pat_mult16x16, #emit_literal2	' compile mult16x16
{3F}                    cmp     pat_callrelpc,  #emit_literal2 	' compile callrelpc


'------------------------------------------------------------------------------
' actual COG code starts below
'------------------------------------------------------------------------------

			org     0
enter
                        jmp     #init
			
'------------------------------------------------------------------------------
' COMPILATION ROUTINES
'------------------------------------------------------------------------------

'' just compile the 2 instructions pointed to by the dest field
emit_literal2
			shr	aux_opcode, #9	' extract dest field
			movs	ccopy, aux_opcode
			jmp	#ccopy_next
			
'' compile a binary operator
'' the instruction in the dispatch table (found in aux_opcode) is the one
'' we want to emit
emit_binaryop
			shr	aux_opcode, #23		' extract instruction field
			movi	pat_binaryop+1, aux_opcode
			movs	ccopy, #pat_binaryop	' set up to copy instructions
			jmp	#ccopy_next		' copy them into place
pat_binaryop
			call	#pop_tos
			add	tos, data	' "add" will be replaced here by the generic binary operator
			


emit_addsp
			and	address, #$0F
            		shl	address, #2
	    		movs	pat_addsp, address
	    		movs	ccopy, #pat_addsp
			jmp	#ccopy_next

			'' compile an emulate sequence
emit_emulate
			sub	address, #32
			movs	pat_emulate, address
			movs	ccopy, #pat_emulate
			jmp	#ccopy_next
			

''
'' code for compiling conditional branches
''
emit_condbranch
			'' replace condition in template
			and	aux_opcode, con_mask
			andn	pat_condbranch+1, con_mask
			or	pat_condbranch+1, aux_opcode
			'' and copy instructions
			movs   ccopy, #pat_condbranch
			jmp    #ccopy_next

pat_condbranch
			jmpret	intern_pc, #imp_condbranch  '' set intern_pc for get_next_pc
  if_z			jmp	#set_pc_rel_data

imp_condbranch
			call	#get_next_pc
			call	#pop_tos
			cmp	tos, #0 wz	'' condition code used when we return
  			call	#discard_tos
  			jmp	intern_pc
			
			' compile a signed or unsigned comparison
			' function to call (cmp_unsigned_impl or
			' cmp_signed_impl) is in dest field of aux_opcode
			' the condition code to be used is in the cond field
			' of aux_opcode
emit_cmp
			mov	data, aux_opcode
			shr	data, #9
			movs	pat_compare, data
			
			'' replace condition
			and	aux_opcode, con_mask
			andn	pat_compare+1, con_mask
			or	pat_compare+1, aux_opcode
			'' and copy instructions
			movs   ccopy, #pat_compare
			jmp    #ccopy_next
			
			' mask for condition codes
con_mask		long	$f<<18


emit_loadsp
			mov	pat_loadstoresp+1, loadsp_call
			jmp	#loadst_do
emit_storesp
			mov	pat_loadstoresp+1, storesp_call
loadst_do
                        and     address, #$1F
                        xor     address, #$10           'Trust me, you need this.
                        shl     address, #2
			movs	pat_loadstoresp, address
			movs	ccopy, #pat_loadstoresp
			jmp	#ccopy_next
			
pat_loadstoresp
			mov	address, #0-0
			call	#imp_loadsp	'' this is actually a dummy that will be overwritten

imp_loadsp
                        add     address, sp
                        call    #push_tos
                        rdlong	tos, address
imp_loadsp_ret
                        ret

imp_storesp
                        add     address, sp
                        wrlong	tos, address
			jmp	#pop_tos	'' will return correctly from there
			'' imp_storesp_ret is at pop_tos_ret
			
loadsp_call		call	#imp_loadsp
storesp_call		call	#imp_storesp


'' compile zpu_im instructions
'' for the first move we have to sign extend the 7 bit immediate
'' we take advantage of the fact that the NEG and MOV instructions differ only
'' by 1 bit:
'' MOV = %101000_001_0_1111_000000000_000000000
'' NEG = %101001_001_0_1111_000000000_000000000
'' so we can mux on 1 bit to toggle between them
''
mov_neg_mask		long	%000001_000_0_0000_000000000_000000000

emit_first_im
			mov	im_flag, #emit_later_im
			shl     address, #(32 - 7)
                        sar     address, #(32 - 7)
			abs	address, address wc
			muxc	pat_first_im+1, mov_neg_mask	    ' set NEG if c, MOV if nc
			movs	pat_first_im+1, address
			movs	ccopy, #pat_first_im
			jmp	#ccopy_next

pat_first_im
			call	#push_tos
			mov	tos, #0-0	' this could become a neg

emit_later_im
                        and     address, #$7F
                       	movs    pat_later_im+1, address
			movs	ccopy, #pat_later_im
                        jmp     #ccopy_next
pat_later_im
			shl	tos, #7
			or	tos, #0-0

'------------------------------------------------------------------------------
' PATTERNS FOR RUNTIME, together with any support functions
'------------------------------------------------------------------------------

pat_breakpoint
			jmpret	intern_pc, #dummy	'' break calls get_next_pc
                        call    #break

div_zero_error
pat_illegal
			call	#break
pat_nop					'' share a nop here
			nop
			nop

pat_pushsp
                        call    #push_tos
			call	#imp_pushsp
			'' the 2 instructions above will execute out of cache,
			'' then continue here
imp_pushsp
                        mov     tos, sp
			sub	tos, zpu_memory_addr
                        add     tos, #4
imp_pushsp_ret
			ret

pat_poppc
                        call    #pop_tos
                        jmp     #set_pc_data

pat_addsp0
			add	tos, tos
			nop
pat_addsp
			mov	address, #0-0
			call	#imp_addsp
			'' the 2 instructions above will execute out of cache,
			'' then continue here
imp_addsp
			add	address, sp
			rdlong	data, address
			add	tos, data
imp_addsp_ret
			ret

pat_load
                        mov     address, tos
			call	#read_long

pat_not
                        xor     tos, minus_one
                        nop
			
pat_flip
                        rev     tos, #32
			nop

pat_store
                        call    #pop_tos
			call	#imp_store
			'' the 2 instructions above will execute out of cache,
			'' then continue here
imp_store
                        mov     address, data
                        call    #pop_tos
                        call    #write_long
imp_store_ret
                        ret

pat_popsp
                        mov     sp, tos
			call	#imp_popsp
imp_popsp
			add	sp, zpu_memory_addr
			rdlong	tos, sp
imp_popsp_ret
			ret


pat_emulate
			mov	address, #0-0
			jmpret	intern_pc, #imp_emulate  '' get_next_pc needs intern_pc set

imp_emulate
			call	#get_next_pc
			call    #push_tos
                        mov     tos, cur_pc               'Push return address
			shl	address, #5
                        mov     cur_pc, address                'Op code to PC
                        jmp     #set_pc


pat_neg
			neg	tos,tos
			nop
pat_pushpc
                        call    #push_tos
			jmpret	intern_pc, #imp_pushpc  '' set intern_pc for get_next_pc
imp_pushpc
			call	#get_next_pc
                        mov     tos, cur_pc
			sub	tos, #1
                        jmp	intern_pc


pat_callrelpc
			mov	data, tos
			jmpret	intern_pc, #call_pc_rel	'' uses get_next_pc, needs internal pc


pat_compare
			jmpret	cmp_ret, #0-0	' 0-0 is replaced by imp_cmp_unsigned or imp_cmp_signed
	if_never	mov	tos, #1

imp_cmp_unsigned
                        call    #pop_tos
                        cmp     data, tos wc,wz
			mov	tos, #0
cmp_ret
			ret

imp_cmp_signed
                        call    #pop_tos
                        cmps    data, tos wc,wz
			mov	tos, #0
			jmp	cmp_ret


pat_pushspadd
			shl	tos, #2
			call	#imp_pushspadd

imp_pushspadd
			add	tos, sp
			sub	tos, zpu_memory_addr
imp_pushspadd_ret
			ret


pat_mult16x16
                        call    #pop_tos
			call	#zpu_mult16x16

'------------------------------------------------------------------------------

' dummy routine to set up intern_pc
dummy
			jmp	intern_pc

' get PC of next instruction (pc+1 in ZPU documentation terms) into cur_pc
'' this relies on intern_pc being set up

get_next_pc
			mov	cur_pc, intern_pc
			add	cur_pc, #1		' 2 COG instructions per ZPU one, so round up
			sub	cur_pc, cur_cache_base	' offset from cache start
			shr	cur_pc, #1		' convert to number of instructions
			add	cur_pc, cur_cache_tag
get_next_pc_ret
			ret

' call PC relative:
' must be called with jmpret intern_pc, #call_pc_rel
' assumes that data contains the offset
call_pc_rel
			call	#get_next_pc
			mov	tos, cur_pc		' save next pc
			'' fall through
' set PC relative from data
set_pc_rel_data
			sub	cur_pc, #1		' adjust to current pc
			add	cur_pc, data
			jmp	#set_pc
' set PC from data
set_pc_data
			mov	cur_pc, data
' set PC from cur_pc
set_pc
			mov	intern_pc, cur_pc
			and	intern_pc, #CACHE_LINE_MASK
			shl	intern_pc, #1		'' 2 COG instrs per ZPU one
			andn	cur_pc, #CACHE_LINE_MASK

			'' is the desired line already in cache?
			cmp	cur_cache_tag, cur_pc wz
    	if_z		jmp	#cache_full
#ifdef TWO_LINE_CACHE
			'' is it in the previous cache line?
			'' in any case our current line is about to become
			'' the second most recently used, so swap
			mov	t1, prev_cache_tag
			mov	prev_cache_tag, cur_cache_tag
			mov	cur_cache_tag, t1

			mov	t1, prev_cache_base
			mov	prev_cache_base, cur_cache_base
			mov	cur_cache_base, t1

			cmp	cur_cache_tag, cur_pc wz
       if_z		jmp	#cache_full
#endif

			mov	cur_cache_tag, cur_pc
  			call	#fill		

cache_full
			add	intern_pc, cur_cache_base
			jmp	intern_pc
			
'------------------------------------------------------------------------------
'ZPU memory space access routines

'Push a LONG onto the stack from "tos"
push_tos

                        wrlong  tos, sp
                        sub     sp, #4
push_tos_ret            ret

'Pop a LONG from the stack into "tos", leave flags alone
'old tos gets placed in "data"
' to just throw old tos away, call discard_tos
pop_tos
			mov	data, tos
discard_tos
			add     sp, #4
			rdlong  tos, sp
discard_tos_ret
pop_tos_ret
imp_storesp_ret
			ret

'Read a LONG from ZPU memory at "address" into "tos"
read_long
			test	address, io_mask wz
	      if_nz	jmp	#special_read
                        mov     memp, address
                        add     memp, zpu_memory_addr
                        rdlong  tos, memp
read_long_ret           ret
special_read
''			cmp     address, uart_address wz
''              if_z      jmp     #in_long
                        cmp     address, timer_address wz
              if_z      mov     tos, cnt
	      if_nz     mov	tos, #$100	' makes the UART happy
                        jmp     read_long_ret
			
''in_long                 mov     tos, #$100
''                        jmp     #read_long_ret

'------------------------------------------------------------------------------

'Write a LONG from "data" to ZPU memory at "address"
write_long              cmp     address, zpu_hub_start wc 'Check for normal memory access
              if_nc     jmp     #write_hub_long
                        mov     memp, address
                        add     memp, zpu_memory_addr
                        wrlong  data, memp

write_long_ret		ret

write_hub_long          cmp     address, zpu_cog_start wc 'Check for HUB memory access
              if_nc     jmp     #write_cog_long

                        sub     address, zpu_hub_start
                        wrlong  data, address
                        jmp     #write_long_ret

write_cog_long          cmp     address, zpu_io_start wc
              if_nc     jmp     #write_io_long

                        shr     address, #2
                        movd    :wcog, address
                        nop
:wcog                   mov     0-0, data
                        jmp     #write_long_ret

write_io_long           wrlong  address, io_port_addr 'Set port address
                        wrlong  data, io_data_addr    'Set port data
                        mov     temp, #io_cmd_out     'Set I/O command to OUT
                        wrlong  temp, io_command_addr
:wait                   rdlong  temp, io_command_addr wz 'Wait for command to be completed
              if_nz     jmp     #:wait
                        jmp     #write_long_ret

'------------------------------------------------------------------------------
'
' copy CNT cog longs
' then jump back to nexti
'
ccopy_next
ccopy
			mov 0-0, 0-0
			add ccopy, cstep
			djnz cnt, #ccopy
			jmp  #nexti
cstep			long (1<<9) + 1

'------------------------------------------------------------------------------

'------------------------------------------------------------------------------
'Maths routines borrowed from the Cluso Spin interpreter.
'In turn orrowed from the Parallax Spin interpreter.
'$F4..F7 = MUL/DIV lower/upper result
'
' a" holds the opcode (lower 5 bits as shown in the first block of code... e.g. MPY=$F4=%10100)
' "x" and "y" are the two numbers to be multiplied (or divided) x * y or x / y, result is in "x" (pushed).
'
' So, if you use this routine with a set to...
'  a = $F4 (multiply, return lower 32 bits)
'  a = $F5 (multiply, return upper 32 bits)
'  a = $F6 (divide, return quotient 32 bits)
'  a = $F7 (divide, return remainder 32 bits)

zpu_mult16x16
                        mov     x, tos
                        and     x, word_mask
                        mov     y, data
                        and     y, word_mask
                        mov     a, #SPIN_MUL_OP
			'' fall through

math_F4                 and     a,#%11111               '<== and mask (need in a)
                        mov     t1,#0
                        mov     t2,#32                  'multiply/divide
                        abs     x,x             wc
                        muxc    a,#%01100
                        abs     y,y             wc,wz
        if_c            xor     a,#%00100
                        test    a,#%00010       wc      'set c if divide (DIV/MOD)
        if_c_and_nz     jmp     #mdiv                   'if divide and y=0, do multiply so result=0
                        shr     x,#1            wc      'multiply
mmul    if_c            add     t1,y            wc
                        rcr     t1,#1           wc
                        rcr     x,#1            wc
                        djnz    t2,#mmul
                        test    a,#%00100       wz
        if_nz           neg     t1,t1
        if_nz           neg     x,x             wz
        if_nz           sub     t1,#1
                        test    a,#%00001       wz
        if_nz           mov     x,t1
                        mov     tos, x
                        jmp     #zpu_mult16x16_ret
mdiv                    shr     y,#1            wc,wz   'divide
                        rcr     t1,#1
        if_nz           djnz    t2,#mdiv
mdiv2                   cmpsub  x,t1            wc
                        rcl     y,#1
                        shr     t1,#1
                        djnz    t2,#mdiv2
                        test    a,#%01000       wc
                        negc    x,x
                        test    a,#%00100       wc
                        test    a,#%00001       wz
        if_z            negc    x,y
                        mov     tos, x
zpu_mult16x16_ret
			ret

'------------------------------------------------------------------------------
' fill a cache line with translated instructions
' cur_pc points to the start of the cache line we need
'------------------------------------------------------------------------------
fill
			movd	ccopy, cur_cache_base
			mov	t2, cur_cache_tag
			add	t2, zpu_memory_addr
			mov	t1, #CACHE_LINE_SIZE
			
			'' initialize im_flag for correct state, based
			'' on the previous byte
			'' if we arrived here by falling through
			'' then the high bit of im_flag is set and we
			'' should keep it
			mov	memp, t2
			sub	memp, #1
			xor	memp, #%11		'XOR for endianness
			rdbyte	opcode, memp
			mov	im_flag, #emit_first_im
			test	opcode, #$80 wz
    if_nz		mov	im_flag, #emit_later_im

transi
			'' translate one instruction
                        mov     memp, t2
                        xor     memp, #%11               'XOR here is an endianess fix.
                        rdbyte  opcode, memp
                        mov     address, opcode
#ifdef SINGLE_STEP
                        call    #break_ss
#endif
			add	t2, #1
			' build the instruction into icache here
			mov	cnt, #2

                        test    opcode, #$80 wz          'Check for IM instruction
              if_nz     jmp     im_flag	     ' compile whichver IM instruction variant we need
	      		mov	im_flag, #emit_first_im
                        cmp     opcode, #$60 wz, wc       'Check for LOADSP instruction
        if_z_or_nc      jmp     #emit_loadsp

                        cmp     opcode, #$40 wz, wc       'Check for STORESPinstruction
        if_z_or_nc      jmp     #emit_storesp

			mov	aux_opcode, opcode
			shl	aux_opcode, #2			' convert to byte address
			add	aux_opcode, dispatch_tab_addr
			rdlong	aux_opcode, aux_opcode
#ifdef SINGLE_STEP
			mov	dbg_data, aux_opcode
#endif
                        jmp     aux_opcode                    'Jump through dispatch table for other ops
nexti
			djnz	t1, #transi
fill_ret
			ret

'------------------------------------------------------------------------------
icache0
			long	0[2*CACHE_LINE_SIZE]

			mov	cur_pc, cur_cache_tag
			add	cur_pc, #CACHE_LINE_SIZE
			jmp	#set_pc

#ifdef TWO_LINE_CACHE
icache1
			long	0[2*CACHE_LINE_SIZE]

			mov	cur_pc, cur_cache_tag
			add	cur_pc, #CACHE_LINE_SIZE
			jmp	#set_pc
#endif

'------------------------------------------------------------------------------

'------------------------------------------------------------------------------
#ifdef SINGLE_STEP
break_ss
			mov	data, t2
			sub	data, zpu_memory_addr
			jmp	#break_intern
#endif

break
			call	#get_next_pc
			mov     data, cur_pc wz
	if_nz  		sub	data, #1
break_intern
                        wrlong  data, pc_addr             'Dump registers to HUB.
			mov     a, sp
			sub	a, zpu_memory_addr
                        wrlong  a, sp_addr
			wrlong	tos, tos_addr
			wrlong  dbg_data, debug_addr
                        mov     a, #io_cmd_break     'Set I/O command to BREAK
                        wrlong  a, io_command_addr
:wait                   rdlong  a, io_command_addr wz
              if_nz     jmp     #:wait
break_ss_ret
break_ret               ret
'------------------------------------------------------------------------------

'------------------------------------------------------------------------------

'------------------------------------------------------------------------------
' ZPU registers and working variables

'This is a nice mess, all Zogs variables are overlaid against this code.
init
address                 mov     address, par             'Pick up first 6 longs of PAR block
zpu_memory_addr         rdlong  zpu_memory_addr, address 'HUB address of the ZPU memory area
memp                    add     address, #4              'Temporary pointer into ZPU memory space
zpu_memory_sz           rdlong  zpu_memory_sz, address   'Size of ZPU memory area in bytes
temp                    add     address, #4          'For temp operands etc
cur_pc                  rdlong  cur_pc, address          'ZPU Program Counter
opcode                  add     address, #4          'Opcode being executed.
sp                      rdlong  sp, address          'ZPU Stack Pointer
tos                     add     address, #4          'Top Of Stack
dispatch_tab_addr       rdlong  dispatch_tab_addr, address'HUB address of instruction dispatch table
data                    add     address, #4          'Data parameter for read, write etc
                      '  rdlong  pasm_addr, address
cpu                     add     address, #4          'The CPU type given by the CONGIG op.

' div_flags was called a
div_flags               rdlong  temp, address        '7th par item is address of ZOG I/O mailbox
io_command_addr         mov     io_command_addr, temp'HUB address of I/O command byte.
x                       add     temp, #4             'Maths var.
io_port_addr            mov     io_port_addr, temp   'HUB address of I/Ö port number
y                       add     temp, #4             'Maths var.
io_data_addr            mov     io_data_addr, temp   'HUB address of I/O data
t1                      add     temp, #4             'Maths var.
pc_addr                 mov     pc_addr, temp        'HUB address of PC
t2                      add     temp, #4             'Maths var.
sp_addr                 mov     sp_addr, temp        'HUB address of SP
coginit_dest            add     temp, #4             'Used for coginit instruction.
tos_addr                mov     tos_addr, temp       'HUB address of tos
a                       add     temp, #4
dm_addr                 mov     dm_addr, temp        'HUB address of decode mask
dbg_data                add     temp, #4
debug_addr              mov     debug_addr, temp     'HUB address of debug register

aux_opcode		mov	cur_pc, #0  	     ' implementation data for translating current opcode byte
			jmp	#set_pc

im_flag			long	emit_first_im    ' selects pattern for IM
'------------------------------------------------------------------------------

'------------------------------------------------------------------------------
' Big constants
minus_one               long $FFFFFFFF
word_mask               long $0000FFFF
uart_address            long $80000024
timer_address           long $80000100
io_mask			long $ff000000

zpu_hub_start           long $10000000  'Start of HUB access window in ZPU memory space
zpu_cog_start           long $10008000  'Start of COG access window in ZPU memory space
zpu_io_start            long $10008800  'Start of IO access window


'' COG internal PC address
intern_pc		long	icache0+1	' store return address here
'' start PC of current cache line
cur_cache_tag		long	$DEADBEEF
'' base of current cache line
cur_cache_base	   	long	icache0

#ifdef TWO_LINE_CACHE
'' last cache line
prev_cache_tag		long	$EEEEEEEE
prev_cache_base		long	icache1
#endif



'------------------------------------------------------------------------------
                        fit     $1F0  ' $198 works, $170 would be ideal, $1F0 is whole thing

'---------------------------------------------------------------------------------------------------------
'The End.

