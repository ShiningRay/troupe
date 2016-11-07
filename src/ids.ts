import * as ip from 'ip';

interface IAddressable {
    /**
     * ip address represented in long int
     */
    address: number; 
    /**
     * port
     */
    port: number;
}



class ProcessAddress implements IAddressable{
    public address: number;
    constructor(address: string | number, public port: number){
        if(typeof address === 'string'){
            this.address = ip.fromString(address);
        } else {
            this.address = address
        }
    }
}