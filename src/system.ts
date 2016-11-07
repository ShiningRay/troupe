
var callbacks: Function[] = [];

export function onBootstrap(cb: Function) {
    callbacks.push(cb);
}

interface ClusterConfig {

}

export function bootstrap(config: ClusterConfig, cb?: Function) {
    var dispatcher = new MessageDispatcher(nodeId);

    callbacks.forEach((fn) => fn());
    if (cb) { cb(); }

}
