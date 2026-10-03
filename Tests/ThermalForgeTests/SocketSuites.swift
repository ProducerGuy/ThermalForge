//
//  SocketSuites.swift
//  ThermalForge
//
//  Parent of every suite that runs a real ConnectionServer or socket pair. `.serialized`
//  applies to everything nested here, so these never run concurrently with each other.
//
//  Why: ConnectionServer's reads go through DispatchIO, whose stream queues run on the
//  default-QoS non-overcommit pool (libdispatch io.c, _dispatch_stream_init). That pool
//  is capped near one active thread per CPU per process, and busy test threads count
//  against it. On a 3-vCPU CI runner, socket tests running side by side starved it and
//  stalled server reads for seconds. Accept-path work (an overcommit queue) was never
//  affected.
//

import Testing

@Suite("Sockets", .serialized)
struct SocketSuites {}
