# RTLNet Source-Available License

Revision 11-13-2026.

Copyright (C) 2026 IronKernel. All rights reserved except as granted below.

## 1. Definitions

- **RTLNet** is the content of this repository: the HDL cores, drivers, firmware, test
  benches, scripts and documents, in source form and in any built form (netlist, bitstream,
  binary).
- **You** is the person or the organisation that uses RTLNet.
- **Product** is any hardware, firmware, FPGA design or service that contains RTLNet or a part
  of it, modified or not, and that You sell, lease, license, deploy for a customer, or use to
  provide a paid service.
- **Design Sources** are everything needed to rebuild the FPGA design and the firmware of a
  Product: the RTL, constraints, block designs, firmware, drivers and build scripts, including
  Your own parts of the design.
- **Changes** are Your modifications of RTLNet files and Your new files that are derived from
  RTLNet files.
- **Paid Features** are the features that IronKernel delivers only under a paid license and
  that are not in this repository. ironkernel.com lists them.

## 2. Evaluation license (no fee)

You may use, copy, modify, simulate, build and run RTLNet, without a fee, for:

- evaluation and development, including prototypes and demonstrations that are not sold;
- research and teaching;
- hobby and personal projects.

Under this section You may not ship, sell, lease or deploy a Product. A Product needs
section 3 or section 4.

## 3. Open Product license (no fee)

You may make, sell and ship a Product without a fee when all of these conditions hold for
as long as You ship it:

1. **Public Design Sources.** You publish the complete Design Sources of the Product, at no
   charge and without registration, under the terms of this license, no later than the day
   the Product first ships. Each later release of the Product has its Design Sources
   published the same way.
2. **Changes contributed back.** You offer every Change to the IronKernel GitHub repository
   as a pull request, no later than 90 days after the Product release that contains it.
   IronKernel may accept, change or decline a pull request. The condition is met by the
   offer.
3. **Notice.** The Product's documentation names RTLNet, gives the address of this
   repository and gives the address of the published Design Sources.

If a condition stops holding, the Open Product license of that Product ends, and section 4
applies to further shipments.

## 4. Commercial license (paid)

A Product whose Design Sources are not public, or that does not meet every condition of
section 3, needs a paid license from IronKernel before it ships. The tiers, the fixed prices
and what each includes are published on ironkernel.com. A paid license
is a separate written agreement; where it differs from this text, it governs for that
Product. Paid licenses carry no royalty and no per-unit fee.

## 5. Paid Features

The Paid Features are not licensed by this text. A demonstration form of a Paid Feature
that IronKernel distributes for evaluation (for example a time-limited netlist) comes with
its own evaluation terms (`demos/LICENSE_DEMO.md`). You may not remove, bypass or extend the time limit of a
demonstration form, and You may not ship it in a Product.

## 6. Conditions for every use

1. **Notices stay.** Copies of RTLNet, modified or not, keep the copyright notices, this
   license file and the file headers.
2. **Marked changes.** A modified file states that it was changed and the date.
3. **Same license for RTLNet.** RTLNet files and Changes stay under this license when You
   pass them on in source form. You may not offer RTLNet, or a work that is mainly RTLNet,
   as a competing IP core product or under different terms.
4. **Third-party parts.** Files that carry another license in their header (for example the
   files derived from lwIP, under the lwIP BSD license) stay under that license. This text
   does not change it.
5. **Names.** This license grants no right to the names IronKernel and RTLNet beyond the
   notice of section 3 and a truthful statement that a design uses RTLNet.

## 7. Contributions

A contribution that You offer to the IronKernel GitHub repository is licensed by You to
IronKernel and to every user of RTLNet under this license, and You also grant IronKernel
the right to include it in versions of RTLNet that IronKernel licenses under paid terms.
You confirm that You have the right to offer it. No separate contributor agreement is
required.

## 8. Patents

Each contributor grants You a license, limited to the use this text permits, under the
contributor's patent claims that its contribution to RTLNet necessarily infringes. This
license grants no right under any third-party patent. Video coding standards, H.264 among
them, are subject to patents held by third parties; a license from those parties, where
one is needed for a Product, is Your responsibility.

If You start a patent claim against IronKernel or a contributor that alleges RTLNet
infringes a patent, Your rights under this license end on the day the claim is filed.

## 9. No warranty

RTLNet is provided as it is, without warranty of any kind, express or implied, including
the warranties of merchantability, fitness for a particular purpose and non-infringement.
RTLNet is not designed or tested for use where a failure can cause death, injury or
serious damage to property.

## 10. Limit of liability

To the extent the law allows, IronKernel and the contributors are not liable for any
damages that arise from the use of RTLNet or from the inability to use it, including
direct, indirect, incidental, special and consequential damages and loss of data or
profit, whatever the legal basis of the claim.

## 11. Termination

Your rights under this license end when You break one of its terms and do not correct the
breach within 90 days after You learn of it. Rights that others received from You under
this license stay in force while they keep to its terms. Sections 9 and 10 stay in force
after the license ends.

## 12. General

- This license is source-available. It is not an open source license as the Open Source
  Initiative defines the term, because sections 3 and 4 restrict commercial use.
- IronKernel may publish later revisions of this license. A release of RTLNet stays under
  the revision it was published with; You may choose a later revision for it.
- This license is governed by the law of the State of Florida, without its conflict-of-law
  rules. The courts located in Florida have exclusive jurisdiction over disputes about it.
- If a court finds one term unenforceable, the other terms stay in force.
- Questions about this license and requests for a paid license go to the contact named on
  ironkernel.com.
