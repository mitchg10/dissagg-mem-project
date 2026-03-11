"""
DEX Profile: RDMA Testbed
"""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab as emulab

pc = portal.Context()
request = pc.makeRequestRSpec()

# Parameters
pc.defineParameter("num_nodes", "Number of nodes",
                   portal.ParameterType.INTEGER, 4)
pc.defineParameter("hw_type", "Hardware type",
                   portal.ParameterType.NODETYPE, "d6515",
                   longDescription="d6515=ConnectX-5 100Gb, "
                   "r650=CX-5+CX-6 100Gb, "
                   "c6320=IB QDR 40Gb")
pc.defineParameter("os_image", "OS Image",
                   portal.ParameterType.IMAGE,
                   "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD")

params = pc.bindParameters()

# Network
lan = request.LAN("rdma-lan")
lan.best_effort = True
lan.vlan_tagging = True
lan.link_multiplexing = True

# Nodes
for i in range(params.num_nodes):
    node = request.RawPC("node-%d" % i)
    node.hardware_type = params.hw_type
    node.disk_image = params.os_image

    # Attach to experiment LAN
    iface = node.addInterface("if1")
    iface.addAddress(pg.IPv4Address("10.10.1.%d" % (i + 1),
                                    "255.255.255.0"))
    lan.addInterface(iface)

    # Add local blockstore
    bs = node.Blockstore("bs-%d" % i, "/mydata")
    bs.size = "100GB"

    # Run setup script once booted
    node.addService(pg.Execute(
        shell="bash",
        command="/local/repository/setup.sh"))

pc.printRequestRSpec(request)
