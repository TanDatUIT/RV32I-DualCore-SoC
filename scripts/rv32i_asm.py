#!/usr/bin/env python3
"""
rv32i_asm.py - Assembler RISC-V RV32I cho SoC Physical Design Final Project.
Hỗ trợ đầy đủ tập lệnh RV32I base + pseudo-instructions cơ bản + directive .word.
Xuất định dạng .hex cho $readmemh trong Verilog.
"""

import sys
import re

REG_MAP = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7, 's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15,
    'a6': 16, 'a7': 17, 's2': 18, 's3': 19, 's4': 20, 's5': 21,
    's6': 22, 's7': 23, 's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31
}
for idx in range(32):
    REG_MAP[f'x{idx}'] = idx


def parse_reg(name):
    key = name.strip().lower()
    if key in REG_MAP:
        return REG_MAP[key]
    raise ValueError(f"Khong nhan dien duoc thanh ghi: {name}")


def parse_imm(val_str):
    return int(val_str.strip(), 0)


def resolve_target(target, pc, labels):
    t = target.strip()
    if t in labels:
        return labels[t] - pc
    return parse_imm(t)


def encode_u_type(opcode, rd, imm):
    imm_val = (imm & 0xFFFFF000) >> 12 if imm > 0xFFFFF else (imm & 0xFFFFF)
    return ((imm_val & 0xFFFFF) << 12) | (rd << 7) | opcode


def encode_i_type(opcode, funct3, rd, rs1, imm):
    imm12 = imm & 0xFFF
    return (imm12 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def encode_s_type(opcode, funct3, rs2, rs1, imm):
    imm12 = imm & 0xFFF
    imm11_5 = (imm12 >> 5) & 0x7F
    imm4_0 = imm12 & 0x1F
    return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm4_0 << 7) | opcode


def encode_b_type(funct3, rs1, rs2, offset):
    if offset < -4096 or offset > 4094 or (offset & 1):
        raise ValueError(f"Branch offset out of range: {offset}")
    imm13 = offset & 0x1FFF
    imm12 = (imm13 >> 12) & 1
    imm11 = (imm13 >> 11) & 1
    imm10_5 = (imm13 >> 5) & 0x3F
    imm4_1 = (imm13 >> 1) & 0xF
    return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm4_1 << 8) | (imm11 << 7) | 0b1100011


def encode_j_type(rd, offset):
    if offset < -1048576 or offset > 1048574 or (offset & 1):
        raise ValueError(f"JAL offset out of range: {offset}")
    imm21 = offset & 0x1FFFFF
    imm20 = (imm21 >> 20) & 1
    imm10_1 = (imm21 >> 1) & 0x3FF
    imm11 = (imm21 >> 11) & 1
    imm19_12 = (imm21 >> 12) & 0xFF
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) | (rd << 7) | 0b1101111


def encode_r_type(funct7, rs2, rs1, funct3, rd, opcode=0b0110011):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


R_OPS = {
    'add':  (0b0000000, 0b000),
    'sub':  (0b0100000, 0b000),
    'sll':  (0b0000000, 0b001),
    'slt':  (0b0000000, 0b010),
    'sltu': (0b0000000, 0b011),
    'xor':  (0b0000000, 0b100),
    'srl':  (0b0000000, 0b101),
    'sra':  (0b0100000, 0b101),
    'or':   (0b0000000, 0b110),
    'and':  (0b0000000, 0b111),
}

I_ARITH_OPS = {
    'addi':  0b000,
    'slti':  0b010,
    'sltiu': 0b011,
    'xori':  0b100,
    'ori':   0b110,
    'andi':  0b111,
}

I_SHIFT_OPS = {
    'slli': (0b0000000, 0b001),
    'srli': (0b0000000, 0b101),
    'srai': (0b0100000, 0b101),
}

LOAD_OPS = {
    'lb':  0b000,
    'lh':  0b001,
    'lw':  0b010,
    'lbu': 0b100,
    'lhu': 0b101,
}

STORE_OPS = {
    'sb': 0b000,
    'sh': 0b001,
    'sw': 0b010,
}

BRANCH_OPS = {
    'beq':  0b000,
    'bne':  0b001,
    'blt':  0b100,
    'bge':  0b101,
    'bltu': 0b110,
    'bgeu': 0b111,
}


def li_parts(imm):
    imm32 = imm & 0xFFFFFFFF
    if (imm32 & 0xFFFFF800) == 0 or (imm32 & 0xFFFFF800) == 0xFFFFF800:
        return [(0x001, imm32 & 0xFFF)]
    lo12 = imm32 & 0xFFF
    hi20 = ((imm32 + 0x800) >> 12) & 0xFFFFF
    if lo12 == 0:
        return [(0x037, hi20)]
    return [(0x037, hi20), (0x013, lo12)]


def assemble(src_lines, origin_addr=0):
    labels = {}
    items = []
    pc = origin_addr

    for raw_line in src_lines:
        line = re.sub(r'#.*', '', raw_line).strip()
        if not line:
            continue
        if ':' in line:
            parts = line.split(':', 1)
            labels[parts[0].strip()] = pc
            line = parts[1].strip()
            if not line:
                continue
        if line.startswith('.'):
            if line.lower().startswith('.word'):
                tokens = re.split(r'[\s,]+', line)[1:]
                for tok in tokens:
                    if tok:
                        items.append((pc, f'.word {tok}'))
                        pc += 4
            continue
        tokens = [t for t in re.split(r'[\s,()]+', line) if t]
        op_p1 = tokens[0].lower()
        inst_pc = pc
        if op_p1 == 'li':
            imm = parse_imm(tokens[2])
            pc += 4 * len(li_parts(imm))
        elif op_p1 == 'la':
            pc += 8
        else:
            pc += 4
        items.append((inst_pc, line))

    words = []
    for pc, line in items:
        tokens = [t for t in re.split(r'[\s,()]+', line) if t]
        op = tokens[0].lower()

        if op == '.word':
            words.append(parse_imm(tokens[1]) & 0xFFFFFFFF)
        elif op == 'li':
            rd = parse_reg(tokens[1])
            parts = li_parts(parse_imm(tokens[2]))
            if len(parts) == 1 and parts[0][0] == 0x001:
                words.append(encode_i_type(0b0010011, 0b000, rd, 0, parts[0][1]))
            else:
                words.append(encode_u_type(0b0110111, rd, parts[0][1]))
                if len(parts) == 2:
                    words.append(encode_i_type(0b0010011, 0b000, rd, rd, parts[1][1]))
        elif op == 'la':
            rd = parse_reg(tokens[1])
            target_name = tokens[2].strip()
            if target_name not in labels:
                raise ValueError(f"Khong tim thay nhan cho lenh la: {line}")
            addr = labels[target_name] & 0xFFFFFFFF
            lo12 = addr & 0xFFF
            hi20 = ((addr + 0x800) >> 12) & 0xFFFFF
            words.append(encode_u_type(0b0110111, rd, hi20))
            words.append(encode_i_type(0b0010011, 0b000, rd, rd, lo12))
        elif op == 'nop':
            words.append(encode_i_type(0b0010011, 0b000, 0, 0, 0))
        elif op == 'mv':
            words.append(encode_i_type(0b0010011, 0b000, parse_reg(tokens[1]), parse_reg(tokens[2]), 0))
        elif op == 'j':
            words.append(encode_j_type(0, resolve_target(tokens[1], pc, labels)))
        elif op == 'ret':
            words.append(encode_i_type(0b1100111, 0b000, 0, 1, 0))
        elif op == 'lui':
            words.append(encode_u_type(0b0110111, parse_reg(tokens[1]), parse_imm(tokens[2])))
        elif op == 'auipc':
            words.append(encode_u_type(0b0010111, parse_reg(tokens[1]), parse_imm(tokens[2])))
        elif op in I_ARITH_OPS:
            words.append(encode_i_type(
                0b0010011, I_ARITH_OPS[op],
                parse_reg(tokens[1]), parse_reg(tokens[2]), parse_imm(tokens[3])
            ))
        elif op in I_SHIFT_OPS:
            funct7, funct3 = I_SHIFT_OPS[op]
            shamt = parse_imm(tokens[3]) & 0x1F
            words.append(encode_i_type(
                0b0010011, funct3,
                parse_reg(tokens[1]), parse_reg(tokens[2]), (funct7 << 5) | shamt
            ))
        elif op in R_OPS:
            funct7, funct3 = R_OPS[op]
            words.append(encode_r_type(
                funct7, parse_reg(tokens[3]), parse_reg(tokens[2]), funct3, parse_reg(tokens[1])
            ))
        elif op in LOAD_OPS:
            words.append(encode_i_type(
                0b0000011, LOAD_OPS[op],
                parse_reg(tokens[1]), parse_reg(tokens[3]), parse_imm(tokens[2])
            ))
        elif op in STORE_OPS:
            words.append(encode_s_type(
                0b0100011, STORE_OPS[op],
                parse_reg(tokens[1]), parse_reg(tokens[3]), parse_imm(tokens[2])
            ))
        elif op in BRANCH_OPS:
            words.append(encode_b_type(
                BRANCH_OPS[op], parse_reg(tokens[1]), parse_reg(tokens[2]),
                resolve_target(tokens[3], pc, labels)
            ))
        elif op == 'jal':
            if len(tokens) == 2:
                words.append(encode_j_type(1, resolve_target(tokens[1], pc, labels)))
            else:
                words.append(encode_j_type(parse_reg(tokens[1]), resolve_target(tokens[2], pc, labels)))
        elif op == 'jalr':
            rd = parse_reg(tokens[1])
            rs1 = parse_reg(tokens[2])
            offset = parse_imm(tokens[3]) if len(tokens) > 3 else 0
            words.append(encode_i_type(0b1100111, 0b000, rd, rs1, offset))
        else:
            raise ValueError(f"Lenh chua duoc ho tro boi mini-assembler: {line}")

    return words


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: rv32i_asm.py <input.s> <output.hex> [origin_addr]")
        sys.exit(1)

    in_file = sys.argv[1]
    out_file = sys.argv[2]
    origin = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0

    with open(in_file, 'r') as f:
        lines = f.readlines()

    words = assemble(lines, origin)
    with open(out_file, 'w') as f:
        for w in words:
            f.write(f"{w:08x}\n")
    print(f"[asm] Compiled {len(words)} words from {in_file} -> {out_file} (origin: 0x{origin:08x})")
