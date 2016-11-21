import {Stage} from './stage'
import _ = require('lodash')
import shortid = require('shortid')

export class Theater {
    static readonly current:Theater=new Theater();
    id:string;
    /**
     * ip address of current machine
     */
    address: string;
    /**
     * indicate if current process is the curator process
     */
    current: boolean;
    stages: Stage[];
    constructor(id:string=process.env.THEATER_ID, address:string=process.env.THEATER_ADDRESS){
        this.id = id;
        this.address = address;
    }

    findStageByPort(port:number):Stage{
        return
    }

    findStageByPid(pid:number):Stage{
        return ;
    }
}

export class TheaterDirectory {

}


/**
 * master logics 
 * represent the master process on each machine  
 * expose some api for manage process on the same machine 
 */
class TheaterCurator {
    constructor(id:string=shortid()){

    }
    /**
     * start cluster on current machine;
     */
    open():Theater{
        return
    }
    /**
     * exit all the process on current machine
     */
    shutdown(){

    }
}
