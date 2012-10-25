owl-promixity
=============

Proximity solver for the Owl Platform.

This solver identifies a transmitter as being in close proximity to a receiver if its received signal strength is above some threshold. If more than one receiver observed a signal strength above the given threshold then the stronger one is chosen as the close proximity receiver. If no receiver is in close proximity then the receiver ID 0 is given as the closest.
