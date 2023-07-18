import FIFOF::*;
import Clocks :: *;
import GetPut :: *;
import BlueAXI :: *;
import BlueLib :: *;
import AXI4LiteMaster :: *;
import StmtFSM :: *;
`include "Config.defines"

typedef struct {
    Bit#(28) length;
    Bit#(64) srcAddr;
    Bit#(64) dstAddr;
} XDMADescriptor deriving (Bits, Eq, FShow);

typedef struct {
    Bool isC2H;
    Bool isEnable;
} ControlDMAIfc deriving (Bits, Eq, FShow);

(* always_ready, always_enabled *)
interface IfcXDMADescriptorGeneratorFab;
    method Bool load;
    method Bit#(64) src_addr;
    method Bit#(64) dst_addr;
    method Bit#(28) len;
    method Bit#(16) ctl;
    (* prefix = "" *) method Action ready((* port = "ready" *) Bool rdy);
endinterface

interface IfcXDMADescriptorGenerator;
    interface IfcAxi4LiteMasterFab liteFab;
    (* prefix = "c2h_dsc_byp" *) interface IfcXDMADescriptorGeneratorFab c2hFab;
    (* prefix = "h2c_dsc_byp" *) interface IfcXDMADescriptorGeneratorFab h2cFab;
    interface Put#(XDMADescriptor) c2h;
    interface Put#(XDMADescriptor) h2c;
    method Action startC2HTransfer;
    method Action stopC2HTransfer;
    method Action startH2CTransfer;
    method Action stopH2CTransfer;
endinterface

module mkXDMADescriptorGenerator(IfcXDMADescriptorGenerator);

    let axi4LiteMaster <- mkAXI4LiteMaster();

    FIFOF#(XDMADescriptor) c2hDescriptorFifo <- mkFIFOF;
    FIFOF#(XDMADescriptor) h2cDescriptorFifo <- mkFIFOF;

    ////////////////////////////////////////////////////////////////////////////
    ///////////////////////   Controller   /////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////

    Reg#(AXI4_Lite_Write_Rs_Pkg) writeResponse <- mkReg(unpack(0));

    Wire#(Bit#(64)) c2h_dsc_byp_src_addr <- mkDWire(0);
    Wire#(Bit#(64)) c2h_dsc_byp_dst_addr <- mkDWire(0);
    Wire#(Bit#(28)) c2h_dsc_byp_len <- mkDWire(0);
    Wire#(Bit#(16)) c2h_dsc_byp_en <- mkDWire(0);
    Wire#(Bool) c2h_dsc_byp_ready <- mkBypassWire();

    Wire#(Bit#(64)) h2c_dsc_byp_src_addr <- mkDWire(0);
    Wire#(Bit#(64)) h2c_dsc_byp_dst_addr <- mkDWire(0);
    Wire#(Bit#(28)) h2c_dsc_byp_len <- mkDWire(0);
    Wire#(Bit#(16)) h2c_dsc_byp_ctl <- mkDWire(0);
    Wire#(Bool) h2c_dsc_byp_ready <- mkBypassWire();

    rule clearWriteResponse;
        let pkg <- axi4LiteMaster.writeResponse.get();
    endrule

    rule c2hForward;
        let pkg = c2hDescriptorFifo.first;
        c2h_dsc_byp_src_addr <= pkg.srcAddr;
        c2h_dsc_byp_dst_addr <= pkg.dstAddr;
        c2h_dsc_byp_len <= pkg.length;
        c2h_dsc_byp_en <= 'b11;
    endrule

    rule c2hTransfer if (c2h_dsc_byp_ready);
        let pkg = c2hDescriptorFifo.first;
        c2hDescriptorFifo.deq();
        printColorTimed(GREEN, $format("Start C2HTransfer %h -> %h (%h)", pkg.srcAddr, pkg.dstAddr, pkg.length));
    endrule

    rule h2cForward;
        let pkg = h2cDescriptorFifo.first;
        h2c_dsc_byp_src_addr <= pkg.srcAddr;
        h2c_dsc_byp_dst_addr <= pkg.dstAddr;
        h2c_dsc_byp_len <= pkg.length;
        h2c_dsc_byp_ctl <= 'b11;
    endrule

    rule h2cTransfer if (h2c_dsc_byp_ready);
        let pkg = h2cDescriptorFifo.first;
        h2cDescriptorFifo.deq();
        printColorTimed(GREEN, $format("Start H2CTransfer %h -> %h (%h)", pkg.srcAddr, pkg.dstAddr, pkg.length));
    endrule

    function Action controlDMA(ControlDMAIfc control);
        return action axi4LiteMaster.writeRequest.put(AXI4_Lite_Write_Rq_Pkg {
            addr: control.isC2H ? 'h1004 : 'h0004,
            data: control.isEnable ? 'h1 : 'h0,
            strb: maxBound,
            prot: UNPRIV_SECURE_DATA
        });
        endaction;
    endfunction

    method Action startC2HTransfer();
        controlDMA(ControlDMAIfc {
            isC2H: True,
            isEnable: True
        });
    endmethod

    method Action stopC2HTransfer();
        controlDMA(ControlDMAIfc {
            isC2H: True,
            isEnable: False
        });
        c2hDescriptorFifo.clear();
    endmethod

    method Action startH2CTransfer();
        controlDMA(ControlDMAIfc {
            isC2H: False,
            isEnable: True
        });
    endmethod

    method Action stopH2CTransfer();
        controlDMA(ControlDMAIfc {
            isC2H: False,
            isEnable: False
        });
        h2cDescriptorFifo.clear();
    endmethod

    interface liteFab = axi4LiteMaster.fab;
    interface IfcXDMADescriptorGeneratorFab c2hFab;
        method load = c2hDescriptorFifo.notEmpty;
        method src_addr = c2h_dsc_byp_src_addr;
        method dst_addr = c2h_dsc_byp_dst_addr;
        method len = c2h_dsc_byp_len;
        method ctl = c2h_dsc_byp_en;
        method ready = c2h_dsc_byp_ready._write;
    endinterface
    interface IfcXDMADescriptorGeneratorFab h2cFab;
        method load = h2cDescriptorFifo.notEmpty;
        method src_addr = h2c_dsc_byp_src_addr;
        method dst_addr = h2c_dsc_byp_dst_addr;
        method len = h2c_dsc_byp_len;
        method ctl = h2c_dsc_byp_ctl;
        method ready = h2c_dsc_byp_ready._write;
    endinterface
    interface c2h = toPut(c2hDescriptorFifo);
    interface h2c = toPut(h2cDescriptorFifo);
endmodule
