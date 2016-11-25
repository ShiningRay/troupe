import { Transport } from './transport'
import { Theater } from './theater'

export class Stage {
    readonly theater: Theater;
    readonly pid: number;
    readonly port: number;
    /**
     * on the same machine with current process
     */
    readonly local: boolean;
    /**
     * is current process?
     */
    readonly current: boolean;
    /**
     * the message transport with current process
     */
    transport?: Transport;
    static current: Stage = new Stage();
    constructor() {
        this.theater = Theater.current;
    }
}


/**
 * expose some api for management purpose 
 */
interface StageDirector {
    /**
     * close current stage and exit
     */
    close();
}