// A made-up machine for the documentation's images: an init script that rewrites, in the
// browser, what the event stream says about the machine (its name, model, CPU, GPU, memory and
// disks; the container's OS is kept) before the dashboard reads it. The tests themselves see the real data.
export const MACHINE = {
  host: "lab-runner-01",
  machine: { manufacturer: "Example Systems", model: "Workstation 7", bios: "1.2.0" },
  cpu: { name: "Example CPU @ 3.6 GHz", maxMHz: 3600 },
  gpus: [{ name: "Example Graphics 770", driver: "31.0.101", resolution: "1920 x 1080", refreshHz: 60 }],
  modules: [{ capacity: 8589934592, speedMHz: 3200, slot: "DIMM 1", manufacturer: "Example" }, { capacity: 8589934592, speedMHz: 3200, slot: "DIMM 2", manufacturer: "Example" }],
  disks: [{ media: "SSD", bus: "NVMe", name: "Example NVMe SSD", health: "Healthy" }],
};

export function mockMachine(machine) {
  const fake = (st) => {
    if (!st) return st;
    return {
      ...st, host: machine.host, machine: machine.machine, cpu: { ...st.cpu, ...machine.cpu }, gpus: machine.gpus,
      memory: { ...st.memory, modules: machine.modules },
      disks: (st.disks?.length ? st.disks : [{ size: 512e9 }]).map((d) => ({ ...d, ...machine.disks[0] })),
    };
  };
  const rewrite = {
    snapshot: (d) => ({ ...d, host: machine.host, device: d.device && { ...d.device, static: fake(d.device.static) } }),
    device_static: fake,
  };
  const add = EventSource.prototype.addEventListener;
  EventSource.prototype.addEventListener = function (name, listener, options) {
    if (!rewrite[name]) return add.call(this, name, listener, options);
    return add.call(this, name, (e) => listener({ data: JSON.stringify(rewrite[name](JSON.parse(e.data))) }), options);
  };
}
