# IronKernel Standard License

Revision 11-21-2026.

Copyright (C) 2026 IronKernel. All rights reserved except as granted below.

This one license text covers the IronKernel products listed in the Schedule at the end. The
same file is in every product repository.

## 1. Definitions

- **Work** is the content of the IronKernel repository that holds this file, and anything
  IronKernel delivers from it: HDL cores, drivers, firmware, tools, test benches, scripts and
  documents, in source form and in any built form (netlist, bitstream, binary).
- **Public Work** is a Work that IronKernel publishes in a public repository. **Private
  Work** is a Work that IronKernel does not publish and delivers, or gives access to, only
  under an Agreement. The Schedule names the class of each product.
- **You** is the person or the organisation that uses the Work.
- **Product** is any hardware, firmware, FPGA design, software or service that contains the
  Work or a part of it, modified or not, and that You sell, lease, license, deploy for a
  customer, or use to provide a paid service.
- **Design Sources** are everything needed to rebuild the FPGA design and the firmware of a
  Product: the RTL, constraints, block designs, firmware, drivers and build scripts, including
  Your own parts of the design.
- **Changes** are Your modifications of files of the Work and Your new files that are derived
  from them.
- **Agreement** is a paid written license or order between IronKernel and You. It names the
  licensed product/SKU, seats or enterprise scope, the deliverables and the fee.

## 2. Evaluation license for a Public Work (no fee)

You may use, copy, modify, simulate, build and run a Public Work, without a fee, for:

- evaluation and development, including prototypes and demonstrations that are not sold;
- research and teaching;
- hobby and personal projects.

Under this section You may not ship, sell, lease or deploy a Product. A Product needs
section 3 or section 4.

## 3. Open Product license for a Public Work (no fee)

You may make, sell and ship a Product that contains a Public Work without a fee when all of
these conditions hold for as long as You ship it:

1. **Public Design Sources.** You publish the complete Design Sources of the Product, at no
   charge and without registration, under the terms of this license, no later than the day
   the Product first ships. Each later release of the Product has its Design Sources
   published the same way.
2. **Changes contributed back.** You offer every Change to the IronKernel GitHub repository
   as a pull request, no later than 90 days after the Product release that contains it.
   IronKernel may accept, change or decline a pull request. The condition is met by the
   offer.
3. **Notice.** The Product's documentation names the Work, gives the address of its
   repository and gives the address of the published Design Sources.

If a condition stops holding, the Open Product license of that Product ends, and section 4
applies to further shipments.

## 4. Commercial license (paid)

A Product whose Design Sources are not public, or that does not meet every condition of
section 3, needs a paid license from IronKernel before it ships. The fixed prices and what
each license includes are published on ironkernel.com. A paid license is an Agreement; where
it differs from this text, it governs for that Product.

The license fee is a one-time fee that covers one Product, identified by its product name or
SKU. A different product/SKU needs its own license unless an enterprise Agreement covers it.
Enterprise licensing for multiple products/SKUs is by quotation. Paid licenses carry no
royalty and no per-unit fee.

A license for one Work grants no right to another Work. Bundles that combine Works under
one fee are published on ironkernel.com.

## 5. Private Works

Sections 2 and 3 do not apply to a Private Work. Access to its repository, possession of a
copy, or knowledge of its contents grants no license. You may use a Private Work only under
an Agreement and only within its scope. A license for a Public Work grants no right to a
Private Work, and publishing a Product's Design Sources does not grant one either.

A Private Work and everything delivered from it are confidential. You may give access to
employees and contractors who need it for licensed work and who are bound by confidentiality
at least as protective as the Agreement. You may not publish it, place it in a public
repository, sublicense it, resell it or pass it on to others. You may not reverse engineer,
decompile or disassemble a netlist or bitstream of a Private Work, except where the law
gives You that right and this term cannot remove it. A Private Work reaches Your customers
only in built form inside the licensed Product.

A demonstration form of a Private Work that IronKernel distributes for evaluation (for
example a time-limited bitstream) comes with its own evaluation terms, in the
`LICENSE_DEMO.md` file of the demonstration package. You may not remove, bypass or extend
the time limit of a demonstration form, and You may not ship it in a Product.

## 6. Development tools licensed by seat

A Work that the Schedule marks as licensed by seat is a Private Work with these terms:

1. A seat is the right of one named person to install, run and modify the tool for Your own
   use during the paid term. The term is one year unless the Agreement states another
   period. The fee, and the support included with a seat, are published on ironkernel.com.
2. You own what You build with the tool. You may use it and ship it in Your products without
   a royalty and without a per-unit fee, during the term and after it ends.
3. Other Works that the tool's board designs contain are licensed for products by this
   license as their own Works, not by the seat.
4. Third-party software that the tool downloads and builds, such as U-Boot, the Linux kernel
   and BusyBox, stays under its own license. Meeting those licenses when You distribute what
   You build is Your responsibility. Vendor tools, such as AMD Vivado and Vitis, are not
   included and are licensed by their vendor.

## 7. Conditions for every use

1. **Notices stay.** Copies of the Work, modified or not, keep the copyright notices, this
   license file and the file headers.
2. **Marked changes.** A modified file states that it was changed and the date.
3. **Same license.** Files of a Public Work and Changes to them stay under this license when
   You pass them on in source form. You may not offer a Work, or a work that is mainly a
   Work, as a competing product or under different terms.
4. **Separately licensed files.** A file that names another license in its header stays
   under that license, and this text does not change it. Examples are the Linux kernel and
   U-Boot driver files that carry `SPDX-License-Identifier: GPL-2.0-only`, and the files
   derived from lwIP under the lwIP BSD license.
5. **Names.** This license grants no right to the name IronKernel or to the product names
   beyond the notice of section 3 and a truthful statement that a design uses the Work.

## 8. Contributions

A contribution that You offer to IronKernel is licensed by You to IronKernel and to every
user of the Work under this license, and You also grant IronKernel the right to include it
in versions that IronKernel licenses under paid terms. You confirm that You have the right
to offer it. No separate contributor agreement is required.

## 9. Patents and standards

Each contributor grants You a license, limited to the use this text permits, under the
contributor's patent claims that its contribution to the Work necessarily infringes. This
license grants no right under any third-party patent. Standards that a Work implements,
H.264, MIPI CSI-2 and HDMI among them, can be subject to patents and to membership, adopter
or licensing terms of third parties; meeting those terms, where they apply to a Product, is
Your responsibility.

If You start a patent claim against IronKernel or a contributor that alleges a Work
infringes a patent, Your rights under this license end on the day the claim is filed.

## 10. No warranty

Except as expressly stated in an Agreement, the Work is provided as it is, without warranty
of any kind, express or implied, including the warranties of merchantability, fitness for a
particular purpose and non-infringement. The Work is not designed or tested for use where a
failure can cause death, injury or serious damage to property.

## 11. Limit of liability

To the extent the law allows, and except as expressly stated in an Agreement, IronKernel and
the contributors are not liable for any damages that arise from the use of the Work or from
the inability to use it, including direct, indirect, incidental, special and consequential
damages and loss of data or profit, whatever the legal basis of the claim.

## 12. Termination

Your rights under this license end when You break one of its terms and do not correct the
breach within 90 days after You learn of it. Unauthorized use or disclosure of a Private
Work grants no rights and must stop immediately. When the term of a seat ends without
renewal, use of the tool stops; what You built during the term stays under section 6.
Rights that others received from You under this license stay in force while they keep to
its terms. Sections 5 (confidentiality), 10 and 11 stay in force after the license ends.

## 13. General

- This license is source-available for Public Works and proprietary for Private Works. It is
  not an open source license as the Open Source Initiative defines the term.
- IronKernel may publish later revisions of this license. A release of a Work stays under
  the revision it was published with; You may choose a later revision for it. A later
  revision does not change an existing Agreement without the parties' written consent.
- This license is governed by the law of the State of Florida, without its conflict-of-law
  rules. The courts located in Florida have exclusive jurisdiction over disputes about it.
- If a court finds one term unenforceable, the other terms stay in force.
- Questions about this license and requests for a paid license go to support@ironkernel.com.

## Schedule: products

| Product | Class | Notes |
|---|---|---|
| **RTLNet** (Ethernet stack) | Public Work | The commercial license has three steps. **UDP**: the RGMII and MII Ethernet MACs, ARP, ping, DHCP and the UDP sockets. **Full**: the UDP step plus the TCP services, checksum offload, firewall and policers, drivers and firmware. **10G**: the Full step plus use of the classifier and firewall at 10 Gb/s with Your own 10G MAC and PCS. Every step includes the full source. A lower step is credited in full toward a higher step for the same Product. |
| **IronH264** (H.264 Constrained Baseline encoder) | Public Work | |
| **IronCapture** (MIPI CSI-2 receiver) | Public Work | |
| **IronVideo** (HDMI and LCD video output) | Public Work | |
| **IronH264 High Profile** (CABAC and 8 x 8 transform extension to IronH264) | Private Work | Delivered as a netlist for the FPGA part named in the Agreement. The license includes the IronH264 commercial license for the same Product, and an IronH264 fee already paid for that Product is credited in full. Annual maintenance is published on ironkernel.com. Source delivery is by quotation. |
| **IronForge** (embedded Linux build tool) | Private Work, licensed by seat | Section 6 applies. Enterprise licenses cover multiple seats by quotation. |
