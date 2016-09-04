import definitions::*;

// TODO: add trace generator?
//          - op and registers (can't do PC due to branches) w/ timestamps (must be able to toggle TS)?
//          - register file trace (initial state and writes?) w/ timestamps (must be able to toggle TS)?
//          - memory writes trace?
//          - branch trace?
//

// TODO: generate make files for everything

module core #(
        parameter imem_addr_width_p = 10,
        parameter net_ID_p = 10'b0000000001
    )
    (
        input  clk,
        input  n_reset,

        input  net_packet_s net_packet_i,
        output net_packet_s net_packet_o,

        input  mem_out_s from_mem_i,
        output mem_in_s  to_mem_o,

        output logic [mask_length_gp-1:0] barrier_o,
        output logic                      exception_o,
        output debug_s                    debug_o,
        output logic [31:0]               data_mem_addr
    );
    
    //---- Adresses and Data ----//
    // Ins. memory address signals
    logic [imem_addr_width_p-1:0] PC_r, PC_n,
                                pc_plus1, imem_addr,
                                imm_jump_add;
                                
    // Ins. memory output
    instruction_s instruction, imem_out, instruction_r;
    
    // Result of ALU, Register file outputs, Data memory output data
    logic [31:0] alu_result, rs_val_or_zero, rd_val_or_zero, rs_val, rd_val;
    
    // Reg. File address
    logic [($bits(instruction.rs_imm))-1:0] rd_addr;
    
    // Data for Reg. File signals
    logic [31:0] rf_wd;
    
    //---- Control signals ----//
    // ALU output to determin whether to jump or not
    logic jump_now;
	 
	 // controller output signals
	 logic valid_to_mem_c, PC_wen_r, PC_wen;
		  
	 // Handshak protocol signals for memory
	 logic yumi_to_mem_c;
    
    // Final signals after network interfere
    logic imem_wen, rf_wen;
    
    // Network operation signals
    logic net_ID_match,      net_PC_write_cmd,  net_imem_write_cmd,
        net_reg_write_cmd, net_bar_write_cmd, net_PC_write_cmd_IDLE;
    
    // Memory stages and stall signals
    dmem_req_state mem_stage_r, mem_stage_n;
	 // this^ was provided, and the following was shown in the lecture
	 //logic [1:0] mem_stage_r, mem_stage_n;
    
    logic stall, stall_non_mem;
    
    // Exception signal
    logic exception_n;
    
    // State machine signals
    state_e state_r,state_n;
    
    //---- network and barrier signals ----//
    instruction_s net_instruction;
    logic [mask_length_gp-1:0] barrier_r,      barrier_n,
                            barrier_mask_r, barrier_mask_n;
	
	 // extra variables for our code
	 logic [31:0] rs_val_stage_ID, rd_val_stage_ID;
    
    //---- Connection to external modules ----//
    
    // Suppress warnings
    assign net_packet_o = net_packet_i;

    // DEBUG Struct
    assign debug_o = {PC_r, instruction, state_r, barrier_mask_r, barrier_r};
    
	 // added by Helen, taken from the lecture
	 //Pipeline stage Registers
     IF_ID_reg_s    IF_ID_reg_n,   IF_ID_reg_r;
     ID_EX_reg_s    ID_EX_reg_n,   ID_EX_reg_r;
     EX_MEM_reg_s   EX_MEM_reg_n,   EX_MEM_reg_r;
     MEM_WB_reg_s   MEM_WB_reg_n,   MEM_WB_reg_r;
	  
	  // for later, this the the Hazards variables
	  logic [1:0] fwdA;
	  logic [1:0] fwdB;
	  logic bubble;
	  //logic [2:0] bubble_c;
	  // Bubble stores the True/False varible -- 1 bit
	  //assign bubble = bubble_c != 0;
	 
	 
/*	Please keep this commented out, we do not need it for this lab (lab3) 
	// This program counter was not shown in the lecture
    // Program counter
    always_ff @ (posedge clk)
        begin
        if (!n_reset)
            begin
            PC_r     <= 0;
            end
        else
            begin
            if (PC_wen)
                begin
                PC_r <= PC_n;
            end
        end
    end */
	 
	 // IF Stage starts here
    // Determine next PC
	 assign PC_wen			= net_PC_write_cmd_IDLE || ~stall;
    assign pc_plus1     = PC_r + 1'b1;  // Increment PC.
    assign imm_jump_add = $signed(ID_EX_reg_r.instruction.rs_imm) + $signed(ID_EX_reg_r.pc);  // Calculate possible branch address.
    
    // Next PC is based on network or the instruction
    always_comb
        begin
        PC_n = pc_plus1;    // Default to the next instruction.
        
        if (net_PC_write_cmd_IDLE)
            begin
            PC_n = net_packet_i.net_addr;
            end
        else
            begin
            unique casez (ID_EX_reg_r.instruction)
                // On a JALR, jump to the address in RS (passed via alu_result).
                kJALR:
                    begin
                    PC_n = alu_result[0+:imem_addr_width_p];
						  end
        
                // Branch instructions
                kBNEQZ, kBEQZ, kBLTZ, kBGTZ:
                    begin
                    // If the branch is taken, use the calculated branch address.
                    if (jump_now)
                        begin
                        PC_n = imm_jump_add;
                    end
                end
                
                default: begin end
            endcase
        end
    end
    
	 assign instruction 				  = PC_wen_r ? imem_out : instruction_r;
	 // Pin's code is the next 2 lines
	 assign IF_ID_reg_n.instruction = instruction;
    assign IF_ID_reg_n.pc          = PC_r;
  
	 // Instruction memory
    instr_mem #(
            .addr_width_p(imem_addr_width_p)
        ) 
        imem (
            .clk(clk),
            .addr_i(imem_addr),
            .instruction_i(net_instruction),
            .wen_i(imem_wen),
            .instruction_o(imem_out)
        );
	 
/* ID Stage starts here */
	 ctrl_sig_s ctrl_sig_o;

    // Decode module
    cl_decode decode (
        .instruction_i(IF_ID_reg_r.instruction),
       .ctrl_sig_o(ctrl_sig_o)
    );
	 
	 // Decode module
/*    cl_decode decode (
        .instruction_i(IF_ID_reg_r.instruction),
        .is_load_op_o(ctrl_sig_o.is_load_op_o),
        .op_writes_rf_o(ctrl_sig_o.op_writes_rf_o),
        .is_store_op_o(ctrl_sig_o.is_store_op_o),
        .is_mem_op_o(ctrl_sig_o.is_mem_op_o),
        .is_byte_op_o(ctrl_sig_o.is_byte_op_o)
    );*/
	 
	 // State machine
    cl_state_machine state_machine (
        .instruction_i(EX_MEM_reg_r.instruction),
        .state_i(state_r),
        .exception_i(exception_o),
        .net_PC_write_cmd_IDLE_i(net_PC_write_cmd_IDLE),
        .stall_i(stall),
        .state_o(state_n)
    );
	 
	 // If either the network or instruction writes to the register file, set write enable.
    assign rf_wen = (((!stall || bubble) &&
							  MEM_WB_reg_r.ctrl_signals.op_writes_rf_o) ||
							  net_reg_write_cmd);
	 
	 assign rd_addr = (net_reg_write_cmd) ? (net_packet_i.net_addr [0+:($bits(instruction.rs_imm))])
													  : ({{($bits(instruction.rs_imm)-$bits(instruction.rd)){1'b0}}, {MEM_WB_reg_r.instruction.rd}});
								
	// Register file
    reg_file #(
				.addr_width_p($bits(instruction.rs_imm))
        )
        rf (
            .clk(clk),
            .rs_addr_i(IF_ID_reg_r.instruction.rs_imm),
            .rd_addr_i({{($bits(instruction.rs_imm)-$bits(instruction_r.rd)){1'b0}},{IF_ID_reg_r.instruction.rd}}),
				// Original
				//.rs_addr_i(instruction_r1.rs_imm),
				//.rd_addr_i(rd_addr),
				//
            .w_addr_i(rd_addr),
            .wen_i(rf_wen),
            .w_data_i(rf_wd),
            .rs_val_o(rs_val),
            .rd_val_o(rd_val)
        );
	  
	  assign rs_val_stage_ID = ( MEM_WB_reg_r.ctrl_signals.op_writes_rf_o && MEM_WB_reg_r.instruction.rd &&
												 MEM_WB_reg_r.instruction.rd === IF_ID_reg_r.instruction.rs_imm ) ? rf_wd : rs_val;
	  assign rd_val_stage_ID = ( MEM_WB_reg_r.ctrl_signals.op_writes_rf_o && MEM_WB_reg_r.instruction.rd &&
												 MEM_WB_reg_r.instruction.rd === IF_ID_reg_r.instruction.rd ) ? rf_wd : rd_val;
		  
     assign ID_EX_reg_n.instruction  = IF_ID_reg_r.instruction;
     assign ID_EX_reg_n.pc           = IF_ID_reg_r.pc;
	  assign ID_EX_reg_n.rs_val		 = rs_val_stage_ID;
	  assign ID_EX_reg_n.rd_val		 = rd_val_stage_ID;
	  assign ID_EX_reg_n.ctrl_signals = ctrl_sig_o;
	  
/* EX Stage starts here */
	// the following teo lines are Pin's code but we do not need them (they are commented out in the lec.)
  //  assign rs_val_or_zero = instruction.rs_imm ? rs_val : 32'b0;
  //  assign rd_val_or_zero = rd_addr            ? rd_val : 32'b0;

/* this is for the hazards */
	always_comb
		begin
			unique casez (fwdA)
				2'b10:
					rs_val_or_zero = EX_MEM_reg_r.alu_result; //EX_MEM_reg_r
				2'b01:
					rs_val_or_zero = rf_wd;
				default
					rs_val_or_zero = ID_EX_reg_r.instruction.rs_imm ? ID_EX_reg_r.rs_val : 32'b0;
			endcase
		end
	
	always_comb
		begin
			unique casez (fwdB)
				2'b10:
					rd_val_or_zero = EX_MEM_reg_r.alu_result; //EX_MEM_reg_r
				2'b01:
					rd_val_or_zero = rf_wd;
				default
					rd_val_or_zero = ID_EX_reg_r.instruction.rd ? ID_EX_reg_r.rd_val : 32'b0 ;
			endcase
		end
		
    // ALU
    alu alu_1 (
            .rd_i(rd_val_or_zero),
            .rs_i(rs_val_or_zero),
            .op_i(ID_EX_reg_r.instruction),
				// Original
				//.rd_i(rd_val_r),
				//.rs_i(rs_val_r),
				//.op_i(instruction_r2),
            .result_o(alu_result),
            .jump_now_o(jump_now)
				);
		  
     assign EX_MEM_reg_n.instruction  = ID_EX_reg_r.instruction;
     assign EX_MEM_reg_n.pc           = ID_EX_reg_r.pc;
	  assign EX_MEM_reg_n.rs_val		  = rs_val_or_zero;
	  assign EX_MEM_reg_n.rd_val		  = rd_val_or_zero;
	  assign EX_MEM_reg_n.ctrl_signals = ID_EX_reg_r.ctrl_signals;
	  assign EX_MEM_reg_n.alu_result	  = alu_result;
	  
/* MEM Stage starts here */
	  assign data_mem_addr = EX_MEM_reg_r.alu_result;

    // Data_mem
    assign to_mem_o = '{
        write_data    : EX_MEM_reg_r.rs_val,
        valid         : valid_to_mem_c,
        wen           : EX_MEM_reg_r.ctrl_signals.is_store_op_o,
        byte_not_word : EX_MEM_reg_r.ctrl_signals.is_byte_op_o,
        yumi          : yumi_to_mem_c
    };
	 
     assign MEM_WB_reg_n.instruction  = EX_MEM_reg_r.instruction;
     assign MEM_WB_reg_n.pc           = EX_MEM_reg_r.pc;
	  assign MEM_WB_reg_n.rs_val		  = EX_MEM_reg_r.rs_val;
	  assign MEM_WB_reg_n.rd_val		  = EX_MEM_reg_r.rd_val;
	  assign MEM_WB_reg_n.ctrl_signals = EX_MEM_reg_r.ctrl_signals;
	  assign MEM_WB_reg_n.alu_result	  = EX_MEM_reg_r.alu_result;
	  assign MEM_WB_reg_n.from_mem_i	  = from_mem_i;
	  
/* WB Stage starts here */
    // Select the write data for register file from network, the PC_plus1 for JALR,
    // data memory or ALU result
    always_comb
        begin
        // When the network sends a reg file write command, take data from network.
        if (net_reg_write_cmd)
            begin
            rf_wd = net_packet_i.net_data;
            end
        // On a JALR, we want to write the return address to the destination register.
        else if (MEM_WB_reg_r.instruction ==? kJALR) // TODO: this is written poorly. 
            begin
            rf_wd = (MEM_WB_reg_r.instruction.rd == 0) ? 0 : MEM_WB_reg_r.pc + 1;
            end
        // On a load, we want to write the data from data memory to the destination register.
        else if (MEM_WB_reg_r.ctrl_signals.is_load_op_o)
            begin
            rf_wd = MEM_WB_reg_r.from_mem_i.read_data;
            end
        // Otherwise, the result should be the ALU output.
        else
            begin
            rf_wd = MEM_WB_reg_r.alu_result;
        end
    end
	 
    // Sequential part, including barrier, exception and state
    always_ff @ (posedge clk)
        begin
        if (!n_reset)
            begin
				PC_r				 <= 0;
				barrier_mask_r  <= 0;
            barrier_r       <= 0;
				//mem_stage_r     <= 0;
				// original
             //   barrier_mask_r  <= {(mask_length_gp){1'b0}};
             //   barrier_r       <= {(mask_length_gp){1'b0}};
				mem_stage_r     <= DMEM_IDLE;
            state_r         <= IDLE;
            exception_o     <= 0;
            PC_wen_r        <= 0;
            instruction_r   <= 0;
				// adding the pipelines
				IF_ID_reg_r		 <= 0;
				ID_EX_reg_r		 <= 0;
				EX_MEM_reg_r	 <= 0;
				MEM_WB_reg_r	 <= 0;
				//bubble_c			 <= 0;
            end
         else
            begin :operate
				if (PC_wen)
					begin :if_PC_wen
						PC_r		<= PC_n;
						if(jump_now)
							begin :Jump_Flush
								IF_ID_reg_r		<= 0;
								ID_EX_reg_r		<= 0;
								EX_MEM_reg_r	<= EX_MEM_reg_n;
								MEM_WB_reg_r	<= MEM_WB_reg_n;
							end :Jump_Flush
						else if (net_PC_write_cmd_IDLE)
							begin :Full_Flush
								IF_ID_reg_r		 <= 0;
								ID_EX_reg_r		 <= 0;
								EX_MEM_reg_r	 <= 0;
								MEM_WB_reg_r	 <= 0;
							end :Full_Flush
						else
							begin :Normal_Pipeline_Flow
								IF_ID_reg_r		<= IF_ID_reg_n;
								ID_EX_reg_r		<= ID_EX_reg_n;
								EX_MEM_reg_r	<= EX_MEM_reg_n;
								MEM_WB_reg_r	<= MEM_WB_reg_n;
							end :Normal_Pipeline_Flow
					end :if_PC_wen
					else if(bubble)
						begin :Pipeline_bubble
							IF_ID_reg_r		<= IF_ID_reg_n;
							ID_EX_reg_r		<= 0;
							EX_MEM_reg_r	<= EX_MEM_reg_n;
							MEM_WB_reg_r	<= MEM_WB_reg_n;
						end :Pipeline_bubble
						
					// From above showing we have four pipecuts
				   //bubble_c       <= (bubble_c +1)%4;	
					
					barrier_mask_r <= barrier_mask_n;
					barrier_r      <= barrier_n;
					state_r        <= state_n;
					exception_o    <= exception_n;
					mem_stage_r    <= mem_stage_n;
					PC_wen_r       <= PC_wen;
					instruction_r <= instruction;
         end :operate
		end	// of always_comb
		
/* Hazards Detect starts here */
	 // stall and memory stages signals
    // rf structural hazard and imem structural hazard (can't load next instruction)
    assign stall_non_mem = (net_reg_write_cmd && MEM_WB_reg_r.ctrl_signals.op_writes_rf_o)
                        || (net_imem_write_cmd);
								
    // Stall if LD/ST still active; or in non-RUN state
    assign stall = stall_non_mem || (mem_stage_n != 0) || (state_r != RUN) || bubble;
	 
   // Launch LD/ST: must hold valid high until data memory acknowledges request.
    assign valid_to_mem_c = EX_MEM_reg_r.ctrl_signals.is_mem_op_o & (mem_stage_r < DMEM_REQ_ACKED);
	 
    always_comb
        begin
        yumi_to_mem_c = 1'b0;
        mem_stage_n   = mem_stage_r;
        
        // Send data memory request.
        if (valid_to_mem_c)
            begin
            mem_stage_n   = DMEM_REQ_SENT;
        end
        
        // Request from data memory acknowledged, must still wait for valid for completion.
        if (from_mem_i.yumi)
            begin
            mem_stage_n   = DMEM_REQ_ACKED;
        end
        
        // If we get a valid from data memmory and can commit the LD/ST this cycle, then 
        // acknowledge dmem's response
        if (from_mem_i.valid & ~stall_non_mem)
            begin
            mem_stage_n   = DMEM_IDLE;   // Request completed, go back to idle.
            yumi_to_mem_c = 1'b1;   // Send acknowledge to data memory to finish access.
        end
    end
	 
	 // Hazard Detection Unit
	hazard_unit haz (.IF_ID_reg_r,
						  .ID_EX_reg_r,
						  .ctrl_sig_o,
						  .EX_MEM_reg_r,
						  .MEM_WB_reg_r,
						  .clk,
						  .jump_now,
						  .bubble,
						  .fwdA,
						  .fwdB);
 
    //---- Datapath with network ----//
    // Detect a valid packet for this core
    assign net_ID_match = (net_packet_i.ID == net_ID_p);
    
    // Network operation
    assign net_PC_write_cmd      = (net_ID_match && (net_packet_i.net_op == PC));       // Receive command from network to update PC.
    assign net_imem_write_cmd    = (net_ID_match && (net_packet_i.net_op == INSTR));    // Receive command from network to write instruction memory.
    assign net_reg_write_cmd     = (net_ID_match && (net_packet_i.net_op == REG));      // Receive command from network to write to reg file.
    assign net_bar_write_cmd     = (net_ID_match && (net_packet_i.net_op == BAR));      // Receive command from network for barrier write.
    assign net_PC_write_cmd_IDLE = (net_PC_write_cmd && (state_r == IDLE));
    
    // Barrier final result, in the barrier mask, 1 means not mask and 0 means mask
    assign barrier_o = barrier_mask_r & barrier_r;

    // The instruction write is just for network
    assign imem_wen  = net_imem_write_cmd;
	 
	 // Selection between network and core for instruction address
    assign imem_addr = (net_imem_write_cmd) ? net_packet_i.net_addr
                                        : PC_n;
    
    // Instructions are shorter than 32 bits of network data
    assign net_instruction = net_packet_i.net_data [0+:($bits(instruction))];
    
    // barrier_mask_n, which stores the mask for barrier signal
    always_comb
        begin
        // Change PC packet
        if (net_bar_write_cmd && (state_r != ERR))
            begin
            barrier_mask_n = net_packet_i.net_data [0+:mask_length_gp];
            end
        else
            begin
            barrier_mask_n = barrier_mask_r;
        end
    end
	 
   // barrier_n signal, which contains the barrier value
    // it can be set by PC write network command if in IDLE
    // or by an an BAR instruction that is committing
    assign barrier_n = net_PC_write_cmd_IDLE
                    ? net_packet_i.net_data[0+:mask_length_gp]
                    : ((EX_MEM_reg_r.instruction ==? kBAR) & ~stall)
                        ? EX_MEM_reg_r.alu_result [0+:mask_length_gp]
                        : barrier_r;
    
    // exception_n signal, which indicates an exception
    // We cannot determine next state as ERR in WORK state, since the instruction
    // must be completed, WORK state means start of any operation and in memory
    // instructions which could take some cycles, it could mean wait for the
    // response of the memory to aknowledge the command. So we signal that we recieved
    // a wrong package, but do not stop the execution. Afterwards the exception_r
    // register is used to avoid extra fetch after this instruction.
    always_comb
        begin
        if ((state_r == ERR) || (net_PC_write_cmd && (state_r != IDLE)))
            begin
            exception_n = 1'b1;
            end
        else
            begin
            exception_n = exception_o;
        end
    end
	 
	/* old provided code

    // Since imem has one cycle delay and we send next cycle's address, PC_n
    assign instruction = PC_wen_r ? imem_out:instruction_r1;
    */

//	 instruction_s instruction_r1;
    // Since imem has one cycle delay and we send next cycle's address, PC_n
/*	 instruction_s instruction_r1;
    assign instruction = (PC_wen_r) ? imem_out:instruction_r1;
    assign IF_ID_reg_n.instruction = instruction;
    assign IF_ID_reg_n.pc          = pc_plus1;
	 
    // Decode module
    cl_decode decode (
        .instruction_i(instruction),
        .is_load_op_o(is_load_op_c),
        .op_writes_rf_o(op_writes_rf_c),
        .is_store_op_o(is_store_op_c),
        .is_mem_op_o(is_mem_op_c),
        .is_byte_op_o(is_byte_op_c)
    );
    
*/
// Pipecut between instruction memory and register file
//Pipecut between imem and reg file
//	 always_ff @(posedge clk)
//		begin
//			if(n_reset)
//				begin
//					instruction_r1 <= instruction;
//					//instruction_r <= instruction;
//				end
//			else
//				begin
//					instruction_r1 <= 0;
//				end
//		end
//	 always_ff @(posedge clk)
//		begin
//			if(n_reset)
//				begin
//					instruction_r1 <= instruction;
//			
//				end
//			else
//				begin
//					instruction_r1 <= 0;
//				
//				end
//		end
	 
    // Selection between network and address included in the instruction which is exeuted
    // Address for Reg. File is shorter than address of Ins. memory in network data
    // Since network can write into immediate registers, the address is wider
    // but for the destination register in an instruction the extra bits must be zero
    // Original
	 // assign rd_addr = (net_reg_write_cmd)
    //                ? (net_packet_i.net_addr [0+:($bits(instruction.rs_imm))])
    //                : ({{($bits(instruction.rs_imm)-$bits(instruction.rd)){1'b0}}
    //                    ,{instruction.rd}});
/*
    
	 assign rd_addr = (net_reg_write_cmd)
                    ? (net_packet_i.net_addr [0+:($bits(instruction.rs_imm))])
                    : ({{($bits(instruction.rs_imm)-$bits(instruction.rd)){1'b0}}
                        ,{IF_ID_reg_r.instruction.rd}});
	 //



	 
	 // Register file
    reg_file #(
				// Original 
            //.addr_width_p($bits(instruction.rs_imm))
				.addr_width_p($bits(instruction.rs_imm))
        )
        rf (
            .clk(clk),
				// Original
            .rs_addr_i(IF_ID_reg_r.instruction.rs_imm),
            .rd_addr_i(rd_addr),
				//.rs_addr_i(instruction_r1.rs_imm),
				//.rd_addr_i(rd_addr),
				//
            .w_addr_i(rd_addr),
            .wen_i(rf_wen),
            .w_data_i(rf_wd),
            .rs_val_o(rs_val),
            .rd_val_o(rd_val)
        );
    
    assign rs_val_or_zero = instruction.rs_imm ? rs_val : 32'b0;
    assign rd_val_or_zero = rd_addr            ? rd_val : 32'b0;
    
*/
	 
	 // Registers for this pipecut //
//	 logic [31:0] rs_val_r;
//	 logic [31:0] rd_val_r;
//	 instruction_s instruction_r2;
	 // Pipecut between Register files and ALU
	 // Sample code from Lab2
//	 always_ff @(posedge clk)
//		begin
//			if(n_reset)
//				begin
//					rd_val_r <= rd_val;
//					rs_val_r <= rs_val;
//					instruction_r2 <= instruction_r1;
//				end
//			else
//				begin
//					rd_val_r <= 0;
//					rs_val_r <= 0;
//					instruction_r2 <= 0;
//				end
//		end 
//  

	
//	 always_ff @(posedge clk)
//		begin
//			if(n_reset)
//				begin
//					rd_val_r <= rd_val_or_zero;
//					rs_val_r <= rs_val_or_zero;
//					instruction_r2 <= instruction_r1;
//				end
//			else
//				begin 
//					rd_val_r <= 0;
//					rs_val_r <= 0;
//					instruction_r2 <= 0;
//				end
//		end
    
endmodule

module hazard_unit( input IF_ID_reg_s IF_ID_reg_r
						 ,input ID_EX_reg_s ID_EX_reg_r
						 ,input ctrl_sig_s ctrl_sig_o
						 ,input EX_MEM_reg_s EX_MEM_reg_r
						 ,input MEM_WB_reg_s MEM_WB_reg_r
						 ,input clk
						 ,input jump_now
						 ,output logic bubble
						 ,output logic [1:0] fwdA
						 ,output logic [1:0] fwdB);
	
	// setting the value of bubble
	assign bubble = ((ctrl_sig_o.is_load_op_o || ctrl_sig_o.is_store_op_o || (IF_ID_reg_r.instruction.rd == ID_EX_reg_r.instruction.rd) || (IF_ID_reg_r.instruction.rs_imm == ID_EX_reg_r.instruction.rd)) 
							&& (ID_EX_reg_r.ctrl_signals.is_store_op_o || ID_EX_reg_r.ctrl_signals.is_load_op_o));
	
	// setting fwdA and fwdB values
	always_comb
	begin
		if ((ID_EX_reg_r.instruction.rs_imm === MEM_WB_reg_r.instruction.rd) &&
			  MEM_WB_reg_r.instruction.rd &&
			  MEM_WB_reg_r.ctrl_signals.op_writes_rf_o &&
			 !((ID_EX_reg_r.instruction.rs_imm === EX_MEM_reg_r.instruction.rd) &&
			  EX_MEM_reg_r.instruction.rd &&
			  MEM_WB_reg_r.ctrl_signals.op_writes_rf_o))
		begin
			fwdA = 2'b01;
		end
		
		else if ((ID_EX_reg_r.instruction.rs_imm == EX_MEM_reg_r.instruction.rd) &&
					 EX_MEM_reg_r.instruction.rd &&
					 EX_MEM_reg_r.ctrl_signals.op_writes_rf_o) 
		begin
			fwdA = 2'b10;
		end
		
		else 
		begin
			fwdA = 2'b00;	// for all other cases
		end
	end // of setting fwdA value
	
	always_comb
	begin
		if ((ID_EX_reg_r.instruction.rd === MEM_WB_reg_r.instruction.rd) &&
			  MEM_WB_reg_r.instruction.rd &&
			  MEM_WB_reg_r.ctrl_signals.op_writes_rf_o &&
			 !((ID_EX_reg_r.instruction.rd === EX_MEM_reg_r.instruction.rd) &&
			  EX_MEM_reg_r.instruction.rd &&
			  MEM_WB_reg_r.ctrl_signals.op_writes_rf_o)) 
		begin
			fwdB = 2'b01;
		end
		
		else if ((ID_EX_reg_r.instruction.rd == EX_MEM_reg_r.instruction.rd) &&
					 EX_MEM_reg_r.instruction.rd &&
					 EX_MEM_reg_r.ctrl_signals.op_writes_rf_o) 
		begin
			fwdB = 2'b10;
		end
		
		else 
		begin
			fwdB = 2'b00; 	// all other cases
		end
	end // of setting fwdB value

endmodule

