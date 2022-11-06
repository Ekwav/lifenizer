import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { map } from 'rxjs/operators';

@Injectable({
  providedIn: 'root'
})
export class AuthService {

  constructor(private httpClient : HttpClient) { }

  getAsyncToken() {
    return this.httpClient.get<TokenResponse>("http://localhost:5000/auth/gettoken").pipe(map((a)=>a.token)).toPromise();
  }


}
export class TokenResponse
{
  public token:string;
}