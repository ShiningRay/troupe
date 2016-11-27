import { AbstractTransport } from '../transport';
export class NullTransport extends AbstractTransport {
    constructor(stage, encoder?, decoder?) {
        super(stage, encoder, decoder)
        // setInterval(() => {
        //     console.log('sending mock data')
        //     this.push({ test: 'test' });
        // }, 1000);
    }

    _read(size?) {

    }

    _write(obj, enc, next) {
        console.log(this.encoder(obj))
        this.push(obj);
        next();
    }
}